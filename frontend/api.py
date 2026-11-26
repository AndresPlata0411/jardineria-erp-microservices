import os

import pandas as pd
import requests
import streamlit as st

BASE = os.getenv("API_BASE", "http://gateway/api")


def _detail(r: requests.Response) -> str:
    try:
        d = r.json().get("detail", r.text)
    except (ValueError, AttributeError):
        return r.text or f"HTTP {r.status_code}"
    if isinstance(d, list):  # errores de validacion de FastAPI (422)
        return "; ".join(f"{'.'.join(map(str, e.get('loc', [])[1:]))}: {e.get('msg')}" for e in d)
    return str(d)


def _headers() -> dict:
    tok = st.session_state.get("token")
    return {"Authorization": f"Bearer {tok}"} if tok else {}


def call(method: str, path: str, **kw):
    """Llama a la API por el gateway. Devuelve JSON, True (sin cuerpo) o None si hubo error (ya mostrado)."""
    try:
        r = requests.request(method, f"{BASE}{path}", headers=_headers(), timeout=15, **kw)
    except requests.RequestException as e:
        st.error(f"No se pudo contactar la API: {e}")
        return None
    if r.status_code == 401 and st.session_state.get("token"):
        st.session_state.clear()
        st.rerun()
    if r.status_code >= 400:
        st.error(_detail(r))
        return None
    return r.json() if r.content else True


def csv_bytes(path: str, **params) -> bytes | None:
    try:
        r = requests.get(f"{BASE}{path}", headers=_headers(), params={**params, "formato": "csv"}, timeout=30)
    except requests.RequestException:
        return None
    return r.content if r.status_code == 200 else None


def login(usuario: str, password: str) -> dict | None:
    try:
        r = requests.post(f"{BASE}/operaciones/auth/login",
                          json={"usuario": usuario, "password": password}, timeout=15)
    except requests.RequestException as e:
        st.error(f"No se pudo contactar la API: {e}")
        return None
    if r.status_code != 200:
        st.error(_detail(r))
        return None
    return r.json()


def df(data) -> pd.DataFrame:
    return pd.DataFrame(data or [])
