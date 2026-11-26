import streamlit as st

from api import call, df

st.header("Catalogos")
tab_prod, tab_prov, tab_emp = st.tabs(["Productos", "Proveedores", "Empleados"])

# ------------------------------------------------------------------ productos
with tab_prod:
    prods = call("GET", "/operaciones/productos", params={"limit": 1000}) or []
    gamas = [g["gama"] for g in call("GET", "/operaciones/gamas") or []]
    provs = call("GET", "/operaciones/proveedores") or []
    prov_ids = [None] + [p["codigo_proveedor"] for p in provs]
    prov_nom = {p["codigo_proveedor"]: p["nombre"] for p in provs}
    fmt_prov = lambda i: "(sin proveedor)" if i is None else f"{i} - {prov_nom[i]}"

    st.dataframe(df(prods), hide_index=True, width="stretch", height=300)
    sub_new, sub_edit = st.tabs(["Nuevo producto", "Editar / reponer"])

    with sub_new:
        with st.form("nuevo_prod", clear_on_submit=True):
            a, b = st.columns(2)
            cod = a.text_input("Codigo *")
            nom = b.text_input("Nombre *")
            gama = a.selectbox("Gama *", gamas)
            prov = b.selectbox("Proveedor", prov_ids, format_func=fmt_prov)
            pv = a.number_input("Precio de venta *", min_value=0.0, step=1.0)
            pp = b.number_input("Precio proveedor", min_value=0.0, step=1.0)
            stock = a.number_input("Stock inicial", min_value=0, step=1)
            smin = b.number_input("Stock minimo", min_value=0, step=1)
            desc = st.text_area("Descripcion")
            if st.form_submit_button("Crear producto"):
                if not (cod and nom):
                    st.error("Codigo y nombre son obligatorios")
                else:
                    res = call("POST", "/operaciones/productos", json=dict(
                        codigo_producto=cod, nombre=nom, gama=gama, codigo_proveedor=prov,
                        precio_venta=pv, precio_proveedor=pp or None, cantidad_en_stock=int(stock),
                        stock_minimo=int(smin), descripcion=desc or None))
                    if res:
                        st.toast(f"Producto {res['codigo_producto']} creado", icon="✅")
                        st.rerun()

    with sub_edit:
        if prods:
            p = st.selectbox("Producto", prods, format_func=lambda p: f"{p['codigo_producto']} - {p['nombre']}")
            with st.form(f"edit_{p['codigo_producto']}"):
                a, b = st.columns(2)
                nom = a.text_input("Nombre", p["nombre"])
                gama = b.selectbox("Gama", gamas, index=gamas.index(p["gama"]) if p["gama"] in gamas else 0)
                pv = a.number_input("Precio de venta", min_value=0.0, step=1.0, value=float(p["precio_venta"]))
                smin = b.number_input("Stock minimo", min_value=0, step=1, value=int(p["stock_minimo"]))
                activo = a.checkbox("Activo", p["activo"])
                if st.form_submit_button("Guardar cambios"):
                    if call("PUT", f"/operaciones/productos/{p['codigo_producto']}", json=dict(
                            nombre=nom, gama=gama, precio_venta=pv, stock_minimo=int(smin), activo=activo)):
                        st.toast("Producto actualizado", icon="✅")
                        st.rerun()
            st.markdown(f"**Reponer stock** (actual: {p['cantidad_en_stock']})")
            r1, r2 = st.columns([1, 3])
            cant = r1.number_input("Cantidad", min_value=1, step=1, key="rep")
            if r2.button("Reponer"):
                if call("POST", f"/operaciones/productos/{p['codigo_producto']}/reponer", json={"cantidad": int(cant)}):
                    st.toast("Stock repuesto", icon="✅")
                    st.rerun()

# ------------------------------------------------------------------ proveedores
with tab_prov:
    provs = call("GET", "/operaciones/proveedores") or []
    st.dataframe(df(provs), hide_index=True, width="stretch")
    with st.form("nuevo_prov", clear_on_submit=True):
        nom = st.text_input("Nombre del proveedor")
        if st.form_submit_button("Crear proveedor") and nom:
            if call("POST", "/operaciones/proveedores", json={"nombre": nom}):
                st.rerun()
    if provs:
        pv = st.selectbox("Proveedor a modificar", provs, format_func=lambda p: f"{p['codigo_proveedor']} - {p['nombre']}")
        nuevo = st.text_input("Nuevo nombre", pv["nombre"], key=f"pn_{pv['codigo_proveedor']}")
        c1, c2, _ = st.columns([1, 1, 4])
        if c1.button("Renombrar"):
            if call("PUT", f"/operaciones/proveedores/{pv['codigo_proveedor']}", json={"nombre": nuevo}):
                st.rerun()
        if c2.button("Eliminar", type="primary"):
            if call("DELETE", f"/operaciones/proveedores/{pv['codigo_proveedor']}"):
                st.rerun()  # con productos asociados la API responde 409 y se muestra el error

# ------------------------------------------------------------------ empleados
with tab_emp:
    emps = call("GET", "/operaciones/empleados") or []
    ofis = [o["codigo_oficina"] for o in call("GET", "/operaciones/oficinas") or []]
    st.dataframe(df(emps), hide_index=True, width="stretch", height=300)
    sub_new, sub_edit = st.tabs(["Nuevo empleado", "Editar"])

    with sub_new:
        with st.form("nuevo_emp", clear_on_submit=True):
            a, b = st.columns(2)
            nom = a.text_input("Nombre *")
            ap1 = b.text_input("Primer apellido *")
            ap2 = a.text_input("Segundo apellido")
            ext = b.text_input("Extension *")
            mail = a.text_input("Email *")
            ofi = b.selectbox("Oficina *", ofis)
            jefe = a.selectbox("Jefe", [None] + [e["codigo_empleado"] for e in emps],
                               format_func=lambda i: "(ninguno)" if i is None else str(i))
            puesto = b.text_input("Puesto")
            if st.form_submit_button("Crear empleado"):
                if not (nom and ap1 and ext and mail):
                    st.error("Completa los campos obligatorios (*)")
                elif call("POST", "/operaciones/empleados", json=dict(
                        nombre=nom, apellido1=ap1, apellido2=ap2 or None, extension=ext, email=mail,
                        codigo_oficina=ofi, codigo_jefe=jefe, puesto=puesto or None)):
                    st.rerun()

    with sub_edit:
        if emps:
            e = st.selectbox("Empleado", emps, format_func=lambda e: f"{e['codigo_empleado']} - {e['nombre']} {e['apellido1']}")
            with st.form(f"edit_emp_{e['codigo_empleado']}"):
                a, b = st.columns(2)
                mail = a.text_input("Email", e["email"])
                puesto = b.text_input("Puesto", e["puesto"] or "")
                ofi = a.selectbox("Oficina", ofis, index=ofis.index(e["codigo_oficina"]) if e["codigo_oficina"] in ofis else 0)
                activo = b.checkbox("Activo", e["activo"])
                if st.form_submit_button("Guardar cambios"):
                    if call("PUT", f"/operaciones/empleados/{e['codigo_empleado']}", json=dict(
                            email=mail, puesto=puesto or None, codigo_oficina=ofi, activo=activo)):
                        st.toast("Empleado actualizado", icon="✅")
                        st.rerun()
