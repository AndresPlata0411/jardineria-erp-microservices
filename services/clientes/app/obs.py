import json
import time

import psycopg
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse


def install(app: FastAPI, service: str) -> None:
    """Log JSON a stdout (visible con `docker compose logs`) y traduccion de errores de BD a HTTP."""

    @app.middleware("http")
    async def log_requests(request: Request, call_next):
        t0 = time.perf_counter()
        status = 500
        try:
            resp = await call_next(request)
            status = resp.status_code
            return resp
        finally:
            print(
                json.dumps(
                    {
                        "service": service,
                        "method": request.method,
                        "path": request.url.path,
                        "user": getattr(request.state, "user", None),
                        "status": status,
                        "ms": round((time.perf_counter() - t0) * 1000, 1),
                    }
                ),
                flush=True,
            )

    # RAISE EXCEPTION de procedimientos/triggers (stock, credito, estado, sobrepago...)
    @app.exception_handler(psycopg.errors.RaiseException)
    async def _raise(_, e):
        return JSONResponse({"detail": e.diag.message_primary}, status_code=409)

    # FK, UNIQUE, CHECK, NOT NULL
    @app.exception_handler(psycopg.errors.IntegrityError)
    async def _integrity(_, e):
        return JSONResponse({"detail": e.diag.message_primary}, status_code=409)

    @app.exception_handler(psycopg.errors.InsufficientPrivilege)
    async def _priv(_, e):
        return JSONResponse({"detail": "Operacion no permitida por la base de datos"}, status_code=403)
