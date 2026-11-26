from decimal import Decimal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from . import db
from .auth import current_user, require_admin

router = APIRouter()
T = "clientes.cliente"


class ClienteIn(BaseModel):
    nombre_cliente: str
    nombre_contacto: str | None = None
    apellido_contacto: str | None = None
    telefono: str
    fax: str | None = None
    linea_direccion1: str
    linea_direccion2: str | None = None
    ciudad: str
    region: str | None = None
    pais: str | None = None
    codigo_postal: str | None = None
    codigo_empleado_rep_ventas: int | None = None
    limite_credito: Decimal = Field(default=Decimal(0), ge=0)
    activo: bool = True


class ClienteUpdate(BaseModel):
    nombre_cliente: str | None = None
    nombre_contacto: str | None = None
    apellido_contacto: str | None = None
    telefono: str | None = None
    fax: str | None = None
    linea_direccion1: str | None = None
    linea_direccion2: str | None = None
    ciudad: str | None = None
    region: str | None = None
    pais: str | None = None
    codigo_postal: str | None = None
    codigo_empleado_rep_ventas: int | None = None
    limite_credito: Decimal | None = Field(default=None, ge=0)
    activo: bool | None = None


@router.get("/clientes")
def listar(q: str | None = None, activo: bool | None = None, limit: int = 200, offset: int = 0,
           user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return c.execute(
            f"""SELECT * FROM {T}
                WHERE (%(q)s::text IS NULL OR nombre_cliente ILIKE '%%' || %(q)s::text || '%%')
                  AND (%(a)s::boolean IS NULL OR activo = %(a)s::boolean)
                ORDER BY codigo_cliente LIMIT %(l)s OFFSET %(o)s""",
            {"q": q, "a": activo, "l": min(limit, 1000), "o": offset},
        ).fetchall()


@router.post("/clientes", status_code=201)
def crear(body: ClienteIn, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        return db.insert(c, T, body.model_dump())


@router.get("/clientes/{codigo}")
def obtener(codigo: int, user: dict = Depends(current_user)):
    with db.tx(user["sub"]) as c:
        row = c.execute(f"SELECT * FROM {T} WHERE codigo_cliente = %s", (codigo,)).fetchone()
        if not row:
            raise HTTPException(404, "Cliente no encontrado")
        row["credito_disponible"] = c.execute(
            "SELECT operaciones.fn_credito_disponible(%s) AS v", (codigo,)
        ).fetchone()["v"]
        return row


@router.put("/clientes/{codigo}")
def actualizar(codigo: int, body: ClienteUpdate, user: dict = Depends(current_user)):
    data = body.model_dump(exclude_unset=True)
    if not data:
        raise HTTPException(400, "Nada que actualizar")
    with db.tx(user["sub"]) as c:
        row = db.update(c, T, "codigo_cliente", codigo, data)
        if not row:
            raise HTTPException(404, "Cliente no encontrado")
        return row


@router.delete("/clientes/{codigo}", status_code=204)
def eliminar(codigo: int, user: dict = Depends(require_admin)):
    # Si tiene pedidos/pagos o el trigger bloquea el borrado -> 409 (ver obs.py)
    with db.tx(user["sub"]) as c:
        if not db.delete(c, T, "codigo_cliente", codigo):
            raise HTTPException(404, "Cliente no encontrado")
