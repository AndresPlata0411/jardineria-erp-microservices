from contextlib import asynccontextmanager

from fastapi import FastAPI

from . import db, obs
from .routes import router


@asynccontextmanager
async def lifespan(_):
    db.pool.open()
    yield
    db.pool.close()


app = FastAPI(title="Servicio operaciones", root_path="/api/operaciones", lifespan=lifespan)
obs.install(app, "operaciones")


@app.get("/health")
def health():
    with db.pool.connection() as c:
        c.execute("SELECT 1")
    return {"status": "ok"}


app.include_router(router)
