from datetime import date, timedelta

import streamlit as st

from api import call, df

FORMAS_PAGO = ["Transferencia", "PayPal", "Cheque", "Efectivo", "Tarjeta"]
ESTADOS_FINALES = {"Entregado", "Rechazado", "Cancelado"}

st.header("Pedidos")
tab_nuevo, tab_seg = st.tabs(["Nuevo pedido", "Seguimiento"])

# ------------------------------------------------------------------ nuevo (caso de uso + transaccion)
with tab_nuevo:
    clientes = call("GET", "/clientes/clientes", params={"activo": True, "limit": 1000}) or []
    productos = call("GET", "/operaciones/productos", params={"activo": True, "limit": 1000}) or []
    if clientes and productos:
        cli = st.selectbox("Cliente", clientes,
                           format_func=lambda c: f"#{c['codigo_cliente']} - {c['nombre_cliente']}")
        info = call("GET", f"/clientes/clientes/{cli['codigo_cliente']}")
        if info:
            st.caption(f"Credito disponible: **{info['credito_disponible']:,.2f}** "
                       f"(limite {float(info['limite_credito']):,.2f})")
        c1, c2 = st.columns([1, 2])
        fecha = c1.date_input("Fecha esperada", date.today() + timedelta(days=7))
        coment = c2.text_input("Comentarios")

        st.subheader("Productos")
        pdf = df(productos)
        f1, f2 = st.columns(2)
        q = f1.text_input("Filtrar por nombre")
        gamas = ["(todas)"] + sorted(pdf["gama"].unique())
        gama = f2.selectbox("Gama", gamas)
        vista = pdf.copy()
        if q:
            vista = vista[vista["nombre"].str.contains(q, case=False, na=False)]
        if gama != "(todas)":
            vista = vista[vista["gama"] == gama]

        carrito = st.session_state.setdefault("carrito", {})
        vista = vista[["codigo_producto", "nombre", "cantidad_en_stock", "precio_venta"]].copy()
        vista["cantidad"] = vista["codigo_producto"].map(carrito).fillna(0).astype(int)
        ed = st.data_editor(
            vista, hide_index=True, width="stretch", height=320, key=f"ed_{q}_{gama}",
            disabled=["codigo_producto", "nombre", "cantidad_en_stock", "precio_venta"],
            column_config={"cantidad": st.column_config.NumberColumn("Cantidad", min_value=0, step=1)},
        )
        for r in ed.itertuples():  # sincroniza con el carrito (sobrevive a cambios de filtro)
            if r.cantidad > 0:
                carrito[r.codigo_producto] = int(r.cantidad)
            else:
                carrito.pop(r.codigo_producto, None)

        if carrito:
            precios = pdf.set_index("codigo_producto")
            resumen = df([{"codigo_producto": k, "nombre": precios.loc[k, "nombre"], "cantidad": v,
                           "stock": int(precios.loc[k, "cantidad_en_stock"]),
                           "subtotal": float(precios.loc[k, "precio_venta"]) * v}
                          for k, v in carrito.items()])
            st.dataframe(resumen, hide_index=True, width="stretch")
            st.metric("Total estimado", f"{resumen['subtotal'].sum():,.2f}")
        else:
            st.info("Agrega cantidades en la tabla para armar el pedido.")

        b1, b2, _ = st.columns([1, 1, 4])
        if b1.button("Crear pedido", type="primary", disabled=not carrito):
            body = {"codigo_cliente": cli["codigo_cliente"], "fecha_esperada": fecha.isoformat(),
                    "comentarios": coment or None,
                    "lineas": [{"codigo_producto": k, "cantidad": v} for k, v in carrito.items()]}
            res = call("POST", "/operaciones/pedidos", json=body)
            if res:
                st.success(f"Pedido #{res['codigo_pedido']} creado")
                st.session_state["carrito"] = {}
        if b2.button("Vaciar"):
            st.session_state["carrito"] = {}
            st.rerun()

# ------------------------------------------------------------------ seguimiento
with tab_seg:
    todos = call("GET", "/operaciones/pedidos", params={"limit": 1000}) or []
    if not todos:
        st.info("No hay pedidos.")
    else:
        estados = ["(todos)"] + sorted({p["estado"] for p in todos})
        est = st.selectbox("Estado", estados)
        lista = [p for p in todos if est == "(todos)" or p["estado"] == est]
        st.dataframe(df(lista), hide_index=True, width="stretch", height=260)

        if lista:
            p = st.selectbox("Pedido", lista, format_func=lambda p: (
                f"#{p['codigo_pedido']} - {p['nombre_cliente']} - {p['estado']} - {float(p['total']):,.2f}"))
            det = call("GET", f"/operaciones/pedidos/{p['codigo_pedido']}")
            if det:
                m1, m2, m3 = st.columns(3)
                m1.metric("Estado", det["estado"])
                m2.metric("Total", f"{float(det['total']):,.2f}")
                m3.metric("Saldo", f"{float(det['saldo']):,.2f}")
                st.markdown("**Detalle**")
                st.dataframe(df(det["detalle"]), hide_index=True, width="stretch")
                st.markdown("**Pagos**")
                st.dataframe(df(det["pagos"]), hide_index=True, width="stretch")

                if det["estado"] in ESTADOS_FINALES:
                    st.caption("Pedido en estado final: sin acciones disponibles.")
                else:
                    a, b, c = st.columns(3)
                    with a:
                        st.markdown("**Registrar pago**")
                        monto = st.number_input("Monto", min_value=0.0, step=1.0,
                                                value=max(float(det["saldo"]), 0.0), key="monto")
                        forma = st.selectbox("Forma de pago", FORMAS_PAGO)
                        if st.button("Pagar"):
                            res = call("POST", f"/operaciones/pedidos/{det['codigo_pedido']}/pagos",
                                       json={"total": monto, "forma_pago": forma})
                            if res:
                                st.toast(f"Pago {res['id_transaccion']} - saldo {res['saldo']}", icon="✅")
                                st.rerun()
                    with b:
                        st.markdown("**Entregar**")
                        fe = st.date_input("Fecha de entrega", date.today())
                        if st.button("Marcar entregado"):
                            if call("POST", f"/operaciones/pedidos/{det['codigo_pedido']}/entregar",
                                    json={"fecha_entrega": fe.isoformat()}):
                                st.toast("Pedido entregado", icon="✅")
                                st.rerun()
                    with c:
                        st.markdown("**Rechazar**")
                        motivo = st.text_input("Motivo")
                        if st.button("Rechazar pedido"):
                            if not motivo:
                                st.error("Indica el motivo")
                            elif call("POST", f"/operaciones/pedidos/{det['codigo_pedido']}/rechazar",
                                      json={"motivo": motivo}):
                                st.toast("Pedido rechazado", icon="✅")
                                st.rerun()
