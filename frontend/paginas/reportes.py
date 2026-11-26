from datetime import date

import streamlit as st

from api import call, csv_bytes, df

st.header("Reportes")

REPORTES = [
    ("Pedidos pendientes", "pedidos-pendientes", False),
    ("Ingresos mensuales", "ingresos-mensuales", True),
    ("Ventas mensuales", "ventas-mensuales", True),
    ("Ventas por gama", "ventas-por-gama", True),
    ("Stock bajo", "stock-bajo", False),
    ("Ranking de clientes", "ranking-clientes", True),
    ("Organigrama", "organigrama", False),
]

tabs = st.tabs([r[0] for r in REPORTES] + ["Ingresos por periodo"])

for tab, (titulo, ruta, graficable) in zip(tabs, REPORTES):
    with tab:
        d = df(call("GET", f"/reportes/{ruta}"))
        if d.empty:
            st.info("Sin datos.")
            continue
        st.dataframe(d, hide_index=True, width="stretch")
        if graficable:
            numericas = [c for c in d.columns[1:] if d[c].dtype.kind in "if"]
            if numericas:
                c1, c2 = st.columns(2)
                x = c1.selectbox("Eje X", list(d.columns), key=f"x_{ruta}")
                y = c2.multiselect("Valores", [c for c in numericas if c != x], default=numericas[:1], key=f"y_{ruta}")
                if y:
                    st.bar_chart(d.head(60).set_index(x)[y])
        data = csv_bytes(f"/reportes/{ruta}")
        if data:
            st.download_button("Descargar CSV", data, file_name=f"{ruta}.csv", mime="text/csv", key=f"csv_{ruta}")

with tabs[-1]:
    c1, c2 = st.columns(2)
    desde = c1.date_input("Desde", date(date.today().year, 1, 1))
    hasta = c2.date_input("Hasta", date.today())
    res = call("GET", "/operaciones/ingresos-periodo", params={"desde": desde.isoformat(), "hasta": hasta.isoformat()})
    if res:
        st.metric("Ingresos (pagos recibidos)", f"{float(res['ingresos'] or 0):,.2f}")
