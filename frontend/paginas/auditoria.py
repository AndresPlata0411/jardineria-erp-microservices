from datetime import date

import streamlit as st

from api import call, csv_bytes, df

st.header("Auditoria")

TABLAS = ["(todas)", "pedido", "detalle_pedido", "pago", "producto", "cliente", "empleado", "proveedor", "usuario"]
c1, c2, c3, c4 = st.columns(4)
tabla = c1.selectbox("Tabla", TABLAS)
oper = c2.selectbox("Operacion", ["(todas)", "INSERT", "UPDATE", "DELETE"])
usar_fechas = c3.checkbox("Filtrar por fecha")
limite = c4.number_input("Maximo de filas", 10, 5000, 200, step=50)

params = {"limit": int(limite)}
if tabla != "(todas)":
    params["tabla"] = tabla
if oper != "(todas)":
    params["operacion"] = oper
if usar_fechas:
    f1, f2 = st.columns(2)
    params["desde"] = f1.date_input("Desde", date.today()).isoformat()
    params["hasta"] = f2.date_input("Hasta", date.today()).isoformat()

d = df(call("GET", "/reportes/auditoria", params=params))
if d.empty:
    st.info("Sin registros.")
else:
    st.caption(f"{len(d)} registros (mas recientes primero). Selecciona una fila para ver el antes y el despues.")
    ev = st.dataframe(d.drop(columns=["datos_old", "datos_new"], errors="ignore"), hide_index=True,
                      width="stretch", on_select="rerun", selection_mode="single-row")
    if ev.selection.rows:
        fila = d.iloc[ev.selection.rows[0]]
        a, b = st.columns(2)
        a.markdown("**Antes**")
        a.json(fila.get("datos_old") or {})
        b.markdown("**Despues**")
        b.json(fila.get("datos_new") or {})
    data = csv_bytes("/reportes/auditoria", **params)
    if data:
        st.download_button("Descargar CSV", data, file_name="auditoria.csv", mime="text/csv")
