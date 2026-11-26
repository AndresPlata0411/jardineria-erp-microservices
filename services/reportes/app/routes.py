import csv
import io
import json
from datetime import date
from typing import Literal

from fastapi import APIRouter, Depends, Response

from . import db
from .auth import current_user, require_admin

router = APIRouter()
Formato = Literal["json", "csv"]


def _out(rows: list[dict], formato: str, nombre: str):
    if formato != "csv":
        return rows
    buf = io.StringIO()
    if rows:
        w = csv.DictWriter(buf, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: (json.dumps(v, default=str) if isinstance(v, (dict, list)) else v)
                        for k, v in r.items()})
    return Response(buf.getvalue(), media_type="text/csv",
                    headers={"Content-Disposition": f'attachment; filename="{nombre}.csv"'})


def _vista(vista: str, formato: str, user: str, limit: int = 5000):
    with db.tx(user) as c:  # 'vista' sale de las constantes de abajo, nunca del usuario
        rows = c.execute(f"SELECT * FROM reportes.{vista} LIMIT %s", (limit,)).fetchall()
    return _out(rows, formato, vista)


@router.get("/pedidos-pendientes")
def pedidos_pendientes(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_pedidos_pendientes", formato, u["sub"])


@router.get("/ingresos-mensuales")
def ingresos_mensuales(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_ingresos_mensuales", formato, u["sub"])


@router.get("/ventas-mensuales")
def ventas_mensuales(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_ventas_mensuales", formato, u["sub"])


@router.get("/ventas-por-gama")
def ventas_por_gama(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_ventas_por_gama", formato, u["sub"])


@router.get("/stock-bajo")
def stock_bajo(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_stock_bajo", formato, u["sub"])


@router.get("/ranking-clientes")
def ranking_clientes(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_ranking_clientes", formato, u["sub"])


@router.get("/organigrama")
def organigrama(formato: Formato = "json", u: dict = Depends(current_user)):
    return _vista("v_organigrama", formato, u["sub"])


@router.get("/auditoria")
def auditoria(tabla: str | None = None, operacion: str | None = None,
              desde: date | None = None, hasta: date | None = None,
              limit: int = 500, formato: Formato = "json", u: dict = Depends(require_admin)):
    with db.tx(u["sub"]) as c:
        rows = c.execute(
            """SELECT * FROM reportes.v_auditoria
               WHERE (%(t)s::text IS NULL OR tabla = %(t)s::text)
                 AND (%(o)s::text IS NULL OR operacion = %(o)s::text)
                 AND (%(d)s::date IS NULL OR fecha >= %(d)s::date)
                 AND (%(h)s::date IS NULL OR fecha < %(h)s::date + 1)
               ORDER BY fecha DESC LIMIT %(l)s""",
            {"t": tabla, "o": operacion.upper() if operacion else None, "d": desde, "h": hasta,
             "l": min(limit, 5000)},
        ).fetchall()
    return _out(rows, formato, "auditoria")
