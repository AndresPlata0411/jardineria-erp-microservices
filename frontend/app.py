import streamlit as st

st.set_page_config(page_title="Jardineria", page_icon="🌱", layout="wide")

from api import login  # noqa: E402  (despues de set_page_config)

if "token" not in st.session_state:
    st.title("🌱 Jardineria")
    with st.form("login"):
        usuario = st.text_input("Usuario")
        password = st.text_input("Contrasena", type="password")
        if st.form_submit_button("Ingresar"):
            res = login(usuario, password)
            if res:
                st.session_state.update(token=res["access_token"], rol=res["rol"], usuario=res["usuario"])
                st.rerun()
    st.stop()

# El menu depende del rol del JWT. Los permisos reales los valida la API.
paginas = [
    st.Page("paginas/pedidos.py", title="Pedidos", icon="🧾", default=True),
    st.Page("paginas/clientes.py", title="Clientes", icon="👥"),
    st.Page("paginas/reportes.py", title="Reportes", icon="📊"),
]
if st.session_state["rol"] == "admin":
    paginas += [
        st.Page("paginas/catalogos.py", title="Catalogos", icon="📦"),
        st.Page("paginas/auditoria.py", title="Auditoria", icon="🔍"),
    ]

with st.sidebar:
    st.caption(f"Usuario: **{st.session_state['usuario']}** ({st.session_state['rol']})")
    if st.button("Cerrar sesion"):
        st.session_state.clear()
        st.rerun()

st.navigation(paginas).run()
