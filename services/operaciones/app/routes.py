import os
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal

import bcrypt
import jwt
from fastapi import APIRouter, Depends, HTTPException
from psycopg.types.json import Jsonb
from pydantic import BaseModel, Field

from . import db
from .auth import ALGO, SECRET, current_user, require_admin

router = APIRouter()
TOKEN_HORAS = int(os.getenv("TOKEN_HORAS", "8"))


# ------------------------------------------------------------------ auth
class Login(BaseModel):
    usuario: str
    password: str


@router.post("/auth/login", tags=["auth"])
def login(b: Login):
    with db.tx(b.usuario) as c:
        u = c.execute(
            "SELECT usuario, password_hash, rol FROM seguridad.usuario WHERE usuario = %s AND activo",
            (b.usuario,),
        ).fetchone()
    ok = False
    if u:
        try:
            ok = bcrypt.checkpw(b.password.encode(), u["password_hash"].encode())
        except ValueError:  # hash que no es bcrypt
            ok = False
    if not ok:
        raise HTTPException(401, "Usuario o contrasena incorrectos")
    exp = datetime.now(timezone.utc) + timedelta(hours=TOKEN_HORAS)
    token = jwt.encode({"sub": u["usuario"], "rol": u["rol"], "exp": exp}, SECRET, algorithm=ALGO)
    return {"access_token": token, "token_type": "bearer", "rol": u["rol"], "usuario": u["usuario"]}


@router.get("/auth/me", tags=["auth"])
def me(user: dict = Depends(current_user)):
    return {"usuario": user["sub"], "rol": user["rol"]}


# ------------------------------------------------------------------ pedidos (caso de uso)
class Linea(BaseModel):
    codigo_producto: str
    cantidad: int = Field(gt=0)


class PedidoIn(BaseModel):
    codigo_cliente: int
    fecha_esperada: date
    comentarios: str | None = None
    lineas: list[Linea] = Field(min_length=1)


class EntregaIn(BaseModel):
    fecha_entrega: date | None = None


class RechazoIn(BaseModel):
    motivo: str = Field(min_length=1)


class PagoIn(BaseModel):
    total: Decimal = Field(gt=0)
    forma_pago: str


@router.get("/pedidos", tags=["pedidos"])
def listar_pedidos(estado: str | None = None, codigo_cliente: int | None = None,
                   limit: int = 200, offset: int = 0, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute(
            """SELECT p.*, cl.nombre_cliente
               FROM operaciones.pedido p JOIN clientes.cliente cl USING (codigo_cliente)
               WHERE (%(e)s::text IS NULL OR p.estado = %(e)s::text)
                 AND (%(c)s::int IS NULL OR p.codigo_cliente = %(c)s::int)
               ORDER BY p.codigo_pedido DESC LIMIT %(l)s OFFSET %(o)s""",
            {"e": estado, "c": codigo_cliente, "l": min(limit, 1000), "o": offset},
        ).fetchall()


def _pedido_completo(c, codigo: int):
    p = c.execute("SELECT * FROM operaciones.pedido WHERE codigo_pedido = %s", (codigo,)).fetchone()
    if not p:
        raise HTTPException(404, "Pedido no encontrado")
    p["detalle"] = c.execute(
        """SELECT d.numero_linea, d.codigo_producto, pr.nombre, d.cantidad, d.precio_unidad,
                  d.cantidad * d.precio_unidad AS subtotal
           FROM operaciones.detalle_pedido d JOIN operaciones.producto pr USING (codigo_producto)
           WHERE d.codigo_pedido = %s ORDER BY d.numero_linea""", (codigo,)).fetchall()
    p["pagos"] = c.execute(
        "SELECT * FROM operaciones.pago WHERE codigo_pedido = %s ORDER BY fecha_pago, id_transaccion",
        (codigo,)).fetchall()
    p["saldo"] = c.execute("SELECT operaciones.fn_saldo_pedido(%s) AS v", (codigo,)).fetchone()["v"]
    return p


@router.get("/pedidos/{codigo}", tags=["pedidos"])
def obtener_pedido(codigo: int, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return _pedido_completo(c, codigo)


@router.post("/pedidos", status_code=201, tags=["pedidos"])
def crear_pedido(b: PedidoIn, user: dict = Depends(current_user)):
    """Transaccion: todo o nada. Stock/credito insuficiente -> 409 y no queda nada a medias."""
    lineas = [l.model_dump() for l in b.lineas]
    with db.tx(user["sub"]) as c:
        row = c.execute(
            "CALL operaciones.sp_crear_pedido(%s, %s, %s, %s, NULL::int)",
            (b.codigo_cliente, b.fecha_esperada, b.comentarios, Jsonb(lineas)),
        ).fetchone()
    return {"codigo_pedido": next(iter(row.values()))}


@router.post("/pedidos/{codigo}/entregar", tags=["pedidos"])
def entregar(codigo: int, b: EntregaIn | None = None, user: dict = Depends(current_user)):
    f = (b.fecha_entrega if b and b.fecha_entrega else date.today())
    with db.tx(user["sub"]) as c:
        c.execute("CALL operaciones.sp_entregar_pedido(%s, %s)", (codigo, f))
        return _pedido_completo(c, codigo)


@router.post("/pedidos/{codigo}/rechazar", tags=["pedidos"])
def rechazar(codigo: int, b: RechazoIn, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        c.execute("CALL operaciones.sp_rechazar_pedido(%s, %s)", (codigo, b.motivo))
        return _pedido_completo(c, codigo)


@router.get("/pedidos/{codigo}/pagos", tags=["pedidos"])
def listar_pagos(codigo: int, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return _pedido_completo(c, codigo)["pagos"]


@router.post("/pedidos/{codigo}/pagos", status_code=201, tags=["pedidos"])
def registrar_pago(codigo: int, b: PagoIn, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        p = c.execute("SELECT codigo_cliente FROM operaciones.pedido WHERE codigo_pedido = %s",
                      (codigo,)).fetchone()
        if not p:
            raise HTTPException(404, "Pedido no encontrado")
        row = c.execute(
            "CALL operaciones.sp_registrar_pago(%s, %s, %s, %s, NULL::text)",
            (p["codigo_cliente"], codigo, b.total, b.forma_pago),
        ).fetchone()
        saldo = c.execute("SELECT operaciones.fn_saldo_pedido(%s) AS v", (codigo,)).fetchone()["v"]
    return {"id_transaccion": next(iter(row.values())), "saldo": saldo}


@router.get("/ingresos-periodo", tags=["pedidos"])
def ingresos(desde: date, hasta: date, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        v = c.execute("SELECT operaciones.fn_ingresos_periodo(%s, %s) AS v", (desde, hasta)).fetchone()["v"]
    return {"desde": desde, "hasta": hasta, "ingresos": v}


# ------------------------------------------------------------------ catalogos
class ProductoIn(BaseModel):
    codigo_producto: str
    nombre: str
    gama: str
    dimensiones: str | None = None
    codigo_proveedor: int | None = None
    descripcion: str | None = None
    cantidad_en_stock: int = Field(default=0, ge=0)
    stock_minimo: int = Field(default=0, ge=0)
    precio_venta: Decimal = Field(ge=0)
    precio_proveedor: Decimal | None = Field(default=None, ge=0)
    activo: bool = True


class ProductoUpdate(BaseModel):  # el stock solo cambia con /reponer o con pedidos
    nombre: str | None = None
    gama: str | None = None
    dimensiones: str | None = None
    codigo_proveedor: int | None = None
    descripcion: str | None = None
    stock_minimo: int | None = Field(default=None, ge=0)
    precio_venta: Decimal | None = Field(default=None, ge=0)
    precio_proveedor: Decimal | None = Field(default=None, ge=0)
    activo: bool | None = None


class ReponerIn(BaseModel):
    cantidad: int = Field(gt=0)


class ProveedorIn(BaseModel):
    nombre: str


class ProveedorUpdate(BaseModel):
    nombre: str | None = None


class EmpleadoIn(BaseModel):
    nombre: str
    apellido1: str
    apellido2: str | None = None
    extension: str
    email: str
    codigo_oficina: str
    codigo_jefe: int | None = None
    puesto: str | None = None
    activo: bool = True


class EmpleadoUpdate(BaseModel):
    nombre: str | None = None
    apellido1: str | None = None
    apellido2: str | None = None
    extension: str | None = None
    email: str | None = None
    codigo_oficina: str | None = None
    codigo_jefe: int | None = None
    puesto: str | None = None
    activo: bool | None = None


@router.get("/productos", tags=["productos"])
def listar_productos(q: str | None = None, gama: str | None = None, activo: bool | None = None,
                     stock_bajo: bool = False, limit: int = 500, offset: int = 0,
                     user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute(
            """SELECT * FROM operaciones.producto
               WHERE (%(q)s::text IS NULL OR nombre ILIKE '%%' || %(q)s::text || '%%')
                 AND (%(g)s::text IS NULL OR gama = %(g)s::text)
                 AND (%(a)s::boolean IS NULL OR activo = %(a)s::boolean)
                 AND (NOT %(sb)s OR cantidad_en_stock <= stock_minimo)
               ORDER BY codigo_producto LIMIT %(l)s OFFSET %(o)s""",
            {"q": q, "g": gama, "a": activo, "sb": stock_bajo, "l": min(limit, 1000), "o": offset},
        ).fetchall()


@router.get("/productos/{codigo}", tags=["productos"])
def obtener_producto(codigo: str, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        r = c.execute("SELECT * FROM operaciones.producto WHERE codigo_producto = %s", (codigo,)).fetchone()
    if not r:
        raise HTTPException(404, "Producto no encontrado")
    return r


@router.post("/productos", status_code=201, tags=["productos"])
def crear_producto(b: ProductoIn, user: dict = Depends(require_admin)):
    with db.tx(user["sub"]) as c:
        return db.insert(c, "operaciones.producto", b.model_dump())


@router.put("/productos/{codigo}", tags=["productos"])
def actualizar_producto(codigo: str, b: ProductoUpdate, user: dict = Depends(require_admin)):
    data = b.model_dump(exclude_unset=True)
    if not data:
        raise HTTPException(400, "Nada que actualizar")
    with db.tx(user["sub"]) as c:
        r = db.update(c, "operaciones.producto", "codigo_producto", codigo, data)
    if not r:
        raise HTTPException(404, "Producto no encontrado")
    return r


@router.post("/productos/{codigo}/reponer", tags=["productos"])
def reponer(codigo: str, b: ReponerIn, user: dict = Depends(require_admin)):
    with db.tx(user["sub"]) as c:
        c.execute("CALL operaciones.sp_reponer_stock(%s, %s)", (codigo, b.cantidad))
        return c.execute("SELECT * FROM operaciones.producto WHERE codigo_producto = %s", (codigo,)).fetchone()


@router.get("/gamas", tags=["catalogos"])
def gamas(user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute("SELECT * FROM operaciones.gama_producto ORDER BY gama").fetchall()


@router.get("/oficinas", tags=["catalogos"])
def oficinas(user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute("SELECT * FROM operaciones.oficina ORDER BY codigo_oficina").fetchall()


@router.get("/proveedores", tags=["catalogos"])
def proveedores(user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute("SELECT * FROM operaciones.proveedor ORDER BY codigo_proveedor").fetchall()


@router.post("/proveedores", status_code=201, tags=["catalogos"])
def crear_proveedor(b: ProveedorIn, user: dict = Depends(require_admin)):
    with db.tx(user["sub"]) as c:
        return db.insert(c, "operaciones.proveedor", b.model_dump())


@router.put("/proveedores/{codigo}", tags=["catalogos"])
def actualizar_proveedor(codigo: int, b: ProveedorUpdate, user: dict = Depends(require_admin)):
    data = b.model_dump(exclude_unset=True)
    if not data:
        raise HTTPException(400, "Nada que actualizar")
    with db.tx(user["sub"]) as c:
        r = db.update(c, "operaciones.proveedor", "codigo_proveedor", codigo, data)
    if not r:
        raise HTTPException(404, "Proveedor no encontrado")
    return r


@router.delete("/proveedores/{codigo}", status_code=204, tags=["catalogos"])
def eliminar_proveedor(codigo: int, user: dict = Depends(require_admin)):
    with db.tx(user["sub"]) as c:  # con productos asociados -> 409 por FK
        if not db.delete(c, "operaciones.proveedor", "codigo_proveedor", codigo):
            raise HTTPException(404, "Proveedor no encontrado")


@router.get("/empleados", tags=["catalogos"])
def empleados(activo: bool | None = None, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute(
            """SELECT * FROM operaciones.empleado
               WHERE (%(a)s::boolean IS NULL OR activo = %(a)s::boolean) ORDER BY codigo_empleado""",
            {"a": activo}).fetchall()


@router.post("/empleados", status_code=201, tags=["catalogos"])
def crear_empleado(b: EmpleadoIn, user: dict = Depends(require_admin)):
    with db.tx(user["sub"]) as c:
        return db.insert(c, "operaciones.empleado", b.model_dump())


@router.put("/empleados/{codigo}", tags=["catalogos"])
def actualizar_empleado(codigo: int, b: EmpleadoUpdate, user: dict = Depends(require_admin)):
    data = b.model_dump(exclude_unset=True)
    if not data:
        raise HTTPException(400, "Nada que actualizar")
    with db.tx(user["sub"]) as c:
        r = db.update(c, "operaciones.empleado", "codigo_empleado", codigo, data)
    if not r:
        raise HTTPException(404, "Empleado no encontrado")
    return r
