import os
from contextlib import contextmanager

from psycopg import sql
from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

pool = ConnectionPool(
    os.environ["DATABASE_URL"],
    min_size=1,
    max_size=10,
    open=False,
    kwargs={"row_factory": dict_row},
)


@contextmanager
def tx(user: str = "sistema"):
    """Una transaccion: commit al salir, rollback si hay excepcion.
    Fija app.user (is_local=true) para que el trigger de auditoria sepa quien fue."""
    with pool.connection() as conn:
        conn.execute("SELECT set_config('app.user', %s, true)", (user,))
        yield conn


def _ident(table: str) -> sql.Identifier:
    return sql.Identifier(*table.split("."))


def insert(conn, table: str, data: dict):
    cols = list(data)
    q = sql.SQL("INSERT INTO {t} ({c}) VALUES ({v}) RETURNING *").format(
        t=_ident(table),
        c=sql.SQL(",").join(map(sql.Identifier, cols)),
        v=sql.SQL(",").join([sql.Placeholder()] * len(cols)),
    )
    return conn.execute(q, list(data.values())).fetchone()


def update(conn, table: str, pk_col: str, pk, data: dict):
    q = sql.SQL("UPDATE {t} SET {s} WHERE {pk} = %s RETURNING *").format(
        t=_ident(table),
        s=sql.SQL(",").join(sql.SQL("{} = %s").format(sql.Identifier(c)) for c in data),
        pk=sql.Identifier(pk_col),
    )
    return conn.execute(q, [*data.values(), pk]).fetchone()


def delete(conn, table: str, pk_col: str, pk):
    q = sql.SQL("DELETE FROM {t} WHERE {pk} = %s RETURNING 1").format(
        t=_ident(table), pk=sql.Identifier(pk_col)
    )
    return conn.execute(q, [pk]).fetchone()
