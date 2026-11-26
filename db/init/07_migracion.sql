-- 07_migracion.sql : carga de datos desde el esquema origen con limpieza.
-- Los triggers de usuario se desactivan SOLO durante esta carga (los datos históricos
-- ya existen: no deben descontar stock, recalcular totales ni llenar la auditoría).

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'operaciones.oficina', 'operaciones.empleado', 'operaciones.gama_producto',
        'operaciones.proveedor', 'operaciones.producto', 'clientes.cliente',
        'operaciones.pedido', 'operaciones.detalle_pedido', 'operaciones.pago',
        'seguridad.usuario']
    LOOP
        EXECUTE format('ALTER TABLE %s DISABLE TRIGGER USER', t);
    END LOOP;
END $$;

-- ===== catálogos =====
INSERT INTO operaciones.oficina
       (codigo_oficina, ciudad, pais, region, codigo_postal, telefono, linea_direccion1, linea_direccion2)
SELECT codigo_oficina, ciudad, pais, NULLIF(region, ''), codigo_postal, telefono,
       linea_direccion1, NULLIF(linea_direccion2, '')
FROM origen.oficina;

INSERT INTO operaciones.empleado
       (codigo_empleado, nombre, apellido1, apellido2, extension, email, codigo_oficina, codigo_jefe, puesto)
SELECT codigo_empleado, nombre, apellido1, NULLIF(apellido2, ''), extension, email,
       codigo_oficina, codigo_jefe, puesto
FROM origen.empleado;

INSERT INTO operaciones.gama_producto (gama, descripcion_texto, descripcion_html, imagen)
SELECT gama, descripcion_texto, descripcion_html, imagen
FROM origen.gama_producto;

-- proveedor sale de normalizar producto.proveedor (texto repetido)
INSERT INTO operaciones.proveedor (nombre)
SELECT DISTINCT proveedor FROM origen.producto
WHERE proveedor IS NOT NULL AND btrim(proveedor) <> ''
ORDER BY 1;

INSERT INTO operaciones.producto
       (codigo_producto, nombre, gama, dimensiones, codigo_proveedor, descripcion,
        cantidad_en_stock, precio_venta, precio_proveedor)
SELECT p.codigo_producto, p.nombre, p.gama, NULLIF(p.dimensiones, ''), pv.codigo_proveedor,
       p.descripcion, p.cantidad_en_stock, p.precio_venta, p.precio_proveedor
FROM origen.producto p
LEFT JOIN operaciones.proveedor pv ON pv.nombre = p.proveedor;

-- ===== clientes =====
-- Limpieza: cliente 12 es duplicado exacto del 6 (sin pedidos ni pagos) -> se omite;
--           mojibake en nombre_contacto; '' -> NULL.
INSERT INTO clientes.cliente
       (codigo_cliente, nombre_cliente, nombre_contacto, apellido_contacto, telefono, fax,
        linea_direccion1, linea_direccion2, ciudad, region, pais, codigo_postal,
        codigo_empleado_rep_ventas, limite_credito)
SELECT codigo_cliente, nombre_cliente, replace(nombre_contacto, 'FraÃ§ois', 'François'),
       apellido_contacto, telefono, NULLIF(fax, ''), linea_direccion1, NULLIF(linea_direccion2, ''),
       ciudad, NULLIF(region, ''), pais, NULLIF(codigo_postal, ''),
       codigo_empleado_rep_ventas, COALESCE(limite_credito, 0)
FROM origen.cliente
WHERE codigo_cliente <> 12;

-- ===== pedidos =====
-- Limpieza de fechas:
--   pedidos 45, 46, 47: fecha_pedido con el mes mal digitado (04 en vez de 03)
--   pedido 90: fecha_esperada con el año mal digitado (2008 en vez de 2009)
--   Entregado sin fecha_entrega (27, 67, 83): fecha_entrega = fecha_esperada
--   Pendiente/Rechazado con fecha_entrega: se anula (no hubo entrega)
INSERT INTO operaciones.pedido
       (codigo_pedido, fecha_pedido, fecha_esperada, fecha_entrega, estado, comentarios, codigo_cliente)
SELECT p.codigo_pedido, f.fecha_pedido, f.fecha_esperada,
       CASE WHEN p.estado = 'Entregado'
            THEN COALESCE(p.fecha_entrega, f.fecha_esperada)
            ELSE NULL END,
       p.estado, p.comentarios, p.codigo_cliente
FROM origen.pedido p
CROSS JOIN LATERAL (
    SELECT CASE WHEN p.codigo_pedido IN (45, 46, 47)
                THEN (p.fecha_pedido - INTERVAL '1 month')::date
                ELSE p.fecha_pedido END AS fecha_pedido,
           CASE WHEN p.codigo_pedido = 90
                THEN (p.fecha_esperada + INTERVAL '1 year')::date
                ELSE p.fecha_esperada END AS fecha_esperada
) f;

-- numero_linea se renumera por pedido (el origen tenía repetidos en los pedidos 9 y 48)
INSERT INTO operaciones.detalle_pedido
       (codigo_pedido, codigo_producto, cantidad, precio_unidad, numero_linea)
SELECT codigo_pedido, codigo_producto, cantidad, precio_unidad,
       ROW_NUMBER() OVER (PARTITION BY codigo_pedido ORDER BY numero_linea, codigo_producto)
FROM origen.detalle_pedido;

UPDATE operaciones.pedido p
SET total = operaciones.fn_total_pedido(p.codigo_pedido);

-- ===== pagos =====
-- Ningún pago del origen coincide con el total de un pedido: se cargan como históricos
-- (codigo_pedido NULL). Sí cuentan como abono del cliente en fn_credito_disponible.
INSERT INTO operaciones.pago (codigo_cliente, id_transaccion, forma_pago, fecha_pago, total)
SELECT codigo_cliente, id_transaccion, forma_pago, fecha_pago, total
FROM origen.pago;

-- ===== secuencias: continuar después de los códigos cargados =====
SELECT setval(pg_get_serial_sequence('operaciones.empleado', 'codigo_empleado'),
              (SELECT MAX(codigo_empleado) FROM operaciones.empleado));
SELECT setval(pg_get_serial_sequence('clientes.cliente', 'codigo_cliente'),
              (SELECT MAX(codigo_cliente) FROM clientes.cliente));
SELECT setval(pg_get_serial_sequence('operaciones.pedido', 'codigo_pedido'),
              (SELECT MAX(codigo_pedido) FROM operaciones.pedido));

-- ===== usuarios de demostración (CAMBIAR las contraseñas antes de exponer el sistema) =====
-- admin / Admin2026!        -> Marcos Magaña (Director General)
-- vendedor1 / Vendedor2026! -> Felipe Rosas (Representante Ventas)
INSERT INTO seguridad.usuario (usuario, password_hash, rol, codigo_empleado) VALUES
 ('admin',     '$2b$12$Ara/AVvi7c.JqjBM3LoAIu35eI2BFRSdhgufiBwxUe6f5dFjCdg6.', 'admin',    1),
 ('vendedor1', '$2b$12$k0txArE3R0zrkHKt7A55tO7v3LN6NtvlQpvIzQrP3oUxOqCLTIov6', 'empleado', 5);

-- ===== reactivar triggers =====
DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'operaciones.oficina', 'operaciones.empleado', 'operaciones.gama_producto',
        'operaciones.proveedor', 'operaciones.producto', 'clientes.cliente',
        'operaciones.pedido', 'operaciones.detalle_pedido', 'operaciones.pago',
        'seguridad.usuario']
    LOOP
        EXECUTE format('ALTER TABLE %s ENABLE TRIGGER USER', t);
    END LOOP;
END $$;

-- Una sola entrada de auditoría que resume la migración
INSERT INTO auditoria.log (esquema, tabla, operacion, usuario_app, usuario_bd, datos_new)
VALUES ('-', 'migracion', 'INSERT', 'sistema', current_user,
        jsonb_build_object(
            'oficinas',  (SELECT COUNT(*) FROM operaciones.oficina),
            'empleados', (SELECT COUNT(*) FROM operaciones.empleado),
            'proveedores', (SELECT COUNT(*) FROM operaciones.proveedor),
            'productos', (SELECT COUNT(*) FROM operaciones.producto),
            'clientes',  (SELECT COUNT(*) FROM clientes.cliente),
            'pedidos',   (SELECT COUNT(*) FROM operaciones.pedido),
            'lineas',    (SELECT COUNT(*) FROM operaciones.detalle_pedido),
            'pagos',     (SELECT COUNT(*) FROM operaciones.pago)));

-- El origen ya cumplió su función (el archivo original sigue en db/origin/)
DROP SCHEMA origen CASCADE;
