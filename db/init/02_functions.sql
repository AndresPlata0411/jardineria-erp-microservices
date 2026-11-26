-- 02_functions.sql : funciones de negocio

-- Total de un pedido = suma de sus líneas
CREATE OR REPLACE FUNCTION operaciones.fn_total_pedido(p_codigo_pedido INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(cantidad * precio_unidad), 0)
    FROM operaciones.detalle_pedido
    WHERE codigo_pedido = p_codigo_pedido;
$$;

-- Saldo pendiente de un pedido = total - pagos asignados a ese pedido
CREATE OR REPLACE FUNCTION operaciones.fn_saldo_pedido(p_codigo_pedido INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT p.total - COALESCE((SELECT SUM(g.total)
                               FROM operaciones.pago g
                               WHERE g.codigo_pedido = p.codigo_pedido), 0)
    FROM operaciones.pedido p
    WHERE p.codigo_pedido = p_codigo_pedido;
$$;

-- Crédito disponible = límite - deuda
-- deuda = pedidos no rechazados - todos los pagos del cliente (mínimo 0)
-- Devuelve NULL si el cliente no existe.
CREATE OR REPLACE FUNCTION operaciones.fn_credito_disponible(p_codigo_cliente INTEGER)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT c.limite_credito - GREATEST(
               COALESCE((SELECT SUM(p.total)
                         FROM operaciones.pedido p
                         WHERE p.codigo_cliente = c.codigo_cliente
                           AND p.estado <> 'Rechazado'), 0)
             - COALESCE((SELECT SUM(g.total)
                         FROM operaciones.pago g
                         WHERE g.codigo_cliente = c.codigo_cliente), 0),
               0)
    FROM clientes.cliente c
    WHERE c.codigo_cliente = p_codigo_cliente;
$$;

-- Ingresos cobrados entre dos fechas (inclusive)
CREATE OR REPLACE FUNCTION operaciones.fn_ingresos_periodo(p_desde DATE, p_hasta DATE)
RETURNS NUMERIC
LANGUAGE sql STABLE AS $$
    SELECT COALESCE(SUM(total), 0)
    FROM operaciones.pago
    WHERE fecha_pago BETWEEN p_desde AND p_hasta;
$$;
