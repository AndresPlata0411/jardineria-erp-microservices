from decimal import Decimal

import streamlit as st

from api import call, df

st.header("Clientes")
es_admin = st.session_state["rol"] == "admin"
tab_lista, tab_nuevo, tab_editar = st.tabs(["Listado", "Nuevo", "Editar / eliminar"])

with tab_lista:
    c1, c2 = st.columns([3, 1])
    q = c1.text_input("Buscar por nombre")
    solo_activos = c2.checkbox("Solo activos", value=True)
    datos = call("GET", "/clientes/clientes", params={"q": q or None, "activo": True if solo_activos else None})
    d = df(datos)
    st.caption(f"{len(d)} clientes")
    st.dataframe(d, hide_index=True, width="stretch")

with tab_nuevo:
    with st.form("nuevo_cliente", clear_on_submit=False):
        a, b = st.columns(2)
        nombre = a.text_input("Nombre del cliente *")
        telefono = b.text_input("Telefono *")
        contacto = a.text_input("Nombre contacto")
        apellido = b.text_input("Apellido contacto")
        dir1 = a.text_input("Direccion *")
        dir2 = b.text_input("Direccion 2")
        ciudad = a.text_input("Ciudad *")
        region = b.text_input("Region")
        pais = a.text_input("Pais")
        cp = b.text_input("Codigo postal")
        limite = a.number_input("Limite de credito", min_value=0.0, step=100.0)
        if st.form_submit_button("Crear cliente"):
            if not (nombre and telefono and dir1 and ciudad):
                st.error("Completa los campos obligatorios (*)")
            else:
                body = dict(nombre_cliente=nombre, telefono=telefono, linea_direccion1=dir1, ciudad=ciudad,
                            nombre_contacto=contacto or None, apellido_contacto=apellido or None,
                            linea_direccion2=dir2 or None, region=region or None, pais=pais or None,
                            codigo_postal=cp or None, limite_credito=limite)
                res = call("POST", "/clientes/clientes", json=body)
                if res:
                    st.success(f"Cliente #{res['codigo_cliente']} creado")

with tab_editar:
    lista = call("GET", "/clientes/clientes", params={"limit": 1000}) or []
    if lista:
        sel = st.selectbox("Cliente", lista, format_func=lambda c: f"#{c['codigo_cliente']} - {c['nombre_cliente']}")
        cli = call("GET", f"/clientes/clientes/{sel['codigo_cliente']}")
        if cli:
            st.metric("Credito disponible", f"{cli['credito_disponible']:,.2f}")
            k = f"edit_{cli['codigo_cliente']}"
            with st.form(k):
                a, b = st.columns(2)
                nombre = a.text_input("Nombre", cli["nombre_cliente"])
                telefono = b.text_input("Telefono", cli["telefono"])
                dir1 = a.text_input("Direccion", cli["linea_direccion1"])
                ciudad = b.text_input("Ciudad", cli["ciudad"])
                limite = a.number_input("Limite de credito", min_value=0.0, step=100.0,
                                        value=float(cli["limite_credito"]))
                activo = b.checkbox("Activo", cli["activo"])
                if st.form_submit_button("Guardar cambios"):
                    res = call("PUT", f"/clientes/clientes/{cli['codigo_cliente']}",
                               json=dict(nombre_cliente=nombre, telefono=telefono, linea_direccion1=dir1,
                                         ciudad=ciudad, limite_credito=limite, activo=activo))
                    if res:
                        st.success("Cliente actualizado")
            if es_admin:
                with st.expander("Zona peligrosa"):
                    st.caption("Si el cliente tiene pedidos o pagos, la base de datos lo impide (409).")
                    if st.button("Eliminar cliente", type="primary", key=f"del_{k}"):
                        if call("DELETE", f"/clientes/clientes/{cli['codigo_cliente']}"):
                            st.toast("Cliente eliminado", icon="✅")
                            st.rerun()
