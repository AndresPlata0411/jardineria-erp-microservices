-- 05_views.sql : vistas en el esquema reportes (las lee reportes_user)

-- Pedidos pendientes con cliente, representante y saldo
CREATE VIEW reportes.v_pedidos_pendientes AS
SELECT p.codigo_pedido,
       p.fecha_pedido,
       p.fecha_esperada,
       (p.fecha_esperada - CURRENT_DATE)       AS dias_para_entrega,
       c.codigo_cliente,
       c.nombre_cliente,
       e.nombre || ' ' || e.apellido1          AS representante,
       p.total,
       COALESCE(pg.pagado, 0)                  AS pagado,
       p.total - COALESCE(pg.pagado, 0)        AS saldo
FROM operaciones.pedido p
JOIN clientes.cliente c            ON c.codigo_cliente = p.codigo_cliente
LEFT JOIN operaciones.empleado e   ON e.codigo_empleado = c.codigo_empleado_rep_ventas
LEFT JOIN (SELECT codigo_pedido, SUM(total) AS pagado
           FROM operaciones.pago
           WHERE codigo_pedido IS NOT NULL
           GROUP BY codigo_pedido) pg ON pg.codigo_pedido = p.codigo_pedido
WHERE p.estado = 'Pendiente';

-- Ventas mensuales (pedidos entregados)
CREATE VIEW reportes.v_ventas_mensuales AS
SELECT date_trunc('month', fecha_entrega)::date AS mes,
       COUNT(*)                                 AS pedidos,
       SUM(total)                               AS ventas
FROM operaciones.pedido
WHERE estado = 'Entregado'
GROUP BY 1;

-- Cobros mensuales por forma de pago
CREATE VIEW reportes.v_ingresos_mensuales AS
SELECT date_trunc('month', fecha_pago)::date AS mes,
       forma_pago,
       COUNT(*)                              AS pagos,
       SUM(total)                            AS cobrado
FROM operaciones.pago
GROUP BY 1, 2;

-- Productos con stock en o bajo el mínimo
CREATE VIEW reportes.v_stock_bajo AS
SELECT p.codigo_producto,
       p.nombre,
       p.gama,
       pv.nombre             AS proveedor,
       p.cantidad_en_stock,
       p.stock_minimo,
       p.precio_proveedor
FROM operaciones.producto p
LEFT JOIN operaciones.proveedor pv ON pv.codigo_proveedor = p.codigo_proveedor
WHERE p.activo AND p.cantidad_en_stock <= p.stock_minimo;

-- Ranking de clientes (incluye clientes sin pedidos)
CREATE VIEW reportes.v_ranking_clientes AS
SELECT c.codigo_cliente,
       c.nombre_cliente,
       c.pais,
       e.nombre || ' ' || e.apellido1  AS representante,
       COALESCE(v.pedidos, 0)          AS pedidos,
       COALESCE(v.comprado, 0)         AS comprado,
       COALESCE(pg.pagado, 0)          AS pagado,
       c.limite_credito,
       RANK() OVER (ORDER BY COALESCE(v.comprado, 0) DESC) AS posicion
FROM clientes.cliente c
LEFT JOIN operaciones.empleado e ON e.codigo_empleado = c.codigo_empleado_rep_ventas
LEFT JOIN (SELECT codigo_cliente, COUNT(*) AS pedidos, SUM(total) AS comprado
           FROM operaciones.pedido
           WHERE estado <> 'Rechazado'
           GROUP BY codigo_cliente) v ON v.codigo_cliente = c.codigo_cliente
LEFT JOIN (SELECT codigo_cliente, SUM(total) AS pagado
           FROM operaciones.pago
           GROUP BY codigo_cliente) pg ON pg.codigo_cliente = c.codigo_cliente;

-- Ventas por gama (incluye gamas sin productos)
CREATE VIEW reportes.v_ventas_por_gama AS
SELECT g.gama,
       COUNT(DISTINCT p.codigo_producto)                                    AS productos,
       COALESCE(SUM(v.cantidad), 0)                                         AS unidades,
       COALESCE(SUM(v.cantidad * v.precio_unidad), 0)                       AS ventas,
       COALESCE(SUM(v.cantidad * (v.precio_unidad - p.precio_proveedor)), 0) AS margen
FROM operaciones.gama_producto g
LEFT JOIN operaciones.producto p ON p.gama = g.gama
LEFT JOIN (SELECT d.codigo_producto, d.cantidad, d.precio_unidad
           FROM operaciones.detalle_pedido d
           JOIN operaciones.pedido pe ON pe.codigo_pedido = d.codigo_pedido
           WHERE pe.estado <> 'Rechazado') v ON v.codigo_producto = p.codigo_producto
GROUP BY g.gama;

-- Organigrama (consulta recursiva sobre empleado.codigo_jefe)
CREATE VIEW reportes.v_organigrama AS
WITH RECURSIVE org AS (
    SELECT e.codigo_empleado, e.nombre, e.apellido1, e.puesto, e.codigo_oficina,
           1 AS nivel,
           (e.nombre || ' ' || e.apellido1) AS ruta
    FROM operaciones.empleado e
    WHERE e.codigo_jefe IS NULL
    UNION ALL
    SELECT e.codigo_empleado, e.nombre, e.apellido1, e.puesto, e.codigo_oficina,
           o.nivel + 1,
           (o.ruta || ' > ' || e.nombre || ' ' || e.apellido1)
    FROM operaciones.empleado e
    JOIN org o ON e.codigo_jefe = o.codigo_empleado
)
SELECT org.codigo_empleado,
       org.nombre || ' ' || org.apellido1 AS empleado,
       org.puesto,
       ofi.ciudad                         AS oficina,
       org.nivel,
       org.ruta,
       (SELECT COUNT(*) FROM clientes.cliente c
        WHERE c.codigo_empleado_rep_ventas = org.codigo_empleado) AS clientes
FROM org
JOIN operaciones.oficina ofi ON ofi.codigo_oficina = org.codigo_oficina
ORDER BY org.ruta;

-- Visor de auditoría (reportes_user no tiene acceso a la tabla; solo a esta vista)
CREATE VIEW reportes.v_auditoria AS
SELECT id, fecha, usuario_app, usuario_bd, esquema, tabla, operacion, datos_old, datos_new
FROM auditoria.log;
