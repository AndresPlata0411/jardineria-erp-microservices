-- 03_procedures.sql : procedimientos (cada CALL es una transacción; un RAISE revierte todo)

-- Crea un pedido con sus líneas. El trigger valida y descuenta el stock.
-- p_lineas: [{"codigo_producto":"FR-1","cantidad":3}, ...]
CREATE OR REPLACE PROCEDURE operaciones.sp_crear_pedido(
    p_codigo_cliente INTEGER,
    p_fecha_esperada DATE,
    p_comentarios    TEXT,
    p_lineas         JSONB,
    INOUT p_codigo_pedido INTEGER DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_linea RECORD;
    v_n     INTEGER := 0;
BEGIN
    -- Bloquea al cliente: serializa pedidos simultáneos del mismo cliente (control de crédito)
    PERFORM 1 FROM clientes.cliente WHERE codigo_cliente = p_codigo_cliente AND activo FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente % no existe o está inactivo', p_codigo_cliente;
    END IF;

    IF p_lineas IS NULL OR jsonb_typeof(p_lineas) <> 'array' OR jsonb_array_length(p_lineas) = 0 THEN
        RAISE EXCEPTION 'El pedido debe tener al menos una línea';
    END IF;
    IF p_fecha_esperada IS NULL OR p_fecha_esperada < CURRENT_DATE THEN
        RAISE EXCEPTION 'La fecha esperada no puede ser anterior a hoy';
    END IF;

    INSERT INTO operaciones.pedido (fecha_esperada, comentarios, codigo_cliente)
    VALUES (p_fecha_esperada, p_comentarios, p_codigo_cliente)
    RETURNING codigo_pedido INTO p_codigo_pedido;

    FOR v_linea IN
        SELECT x.codigo_producto, SUM(x.cantidad)::INTEGER AS cantidad
        FROM jsonb_to_recordset(p_lineas) AS x(codigo_producto TEXT, cantidad INTEGER)
        GROUP BY x.codigo_producto
        ORDER BY x.codigo_producto
    LOOP
        v_n := v_n + 1;
        INSERT INTO operaciones.detalle_pedido
               (codigo_pedido, codigo_producto, cantidad, precio_unidad, numero_linea)
        SELECT p_codigo_pedido, pr.codigo_producto, v_linea.cantidad, pr.precio_venta, v_n
        FROM operaciones.producto pr
        WHERE pr.codigo_producto = v_linea.codigo_producto AND pr.activo;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no existe o está inactivo', v_linea.codigo_producto;
        END IF;
    END LOOP;

    IF operaciones.fn_credito_disponible(p_codigo_cliente) < 0 THEN
        RAISE EXCEPTION 'Crédito insuficiente: el pedido supera el límite de crédito del cliente';
    END IF;
END $$;

-- Pendiente -> Entregado
CREATE OR REPLACE PROCEDURE operaciones.sp_entregar_pedido(
    p_codigo_pedido INTEGER,
    p_fecha_entrega DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado TEXT;
BEGIN
    SELECT estado INTO v_estado
    FROM operaciones.pedido WHERE codigo_pedido = p_codigo_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe', p_codigo_pedido;
    END IF;
    IF v_estado <> 'Pendiente' THEN
        RAISE EXCEPTION 'Solo se pueden entregar pedidos Pendientes (estado actual: %)', v_estado;
    END IF;

    UPDATE operaciones.pedido
    SET estado = 'Entregado', fecha_entrega = p_fecha_entrega
    WHERE codigo_pedido = p_codigo_pedido;
END $$;

-- Pendiente -> Rechazado (el trigger devuelve el stock)
CREATE OR REPLACE PROCEDURE operaciones.sp_rechazar_pedido(
    p_codigo_pedido INTEGER,
    p_motivo        TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado TEXT;
BEGIN
    IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
        RAISE EXCEPTION 'Debe indicar el motivo del rechazo';
    END IF;

    SELECT estado INTO v_estado
    FROM operaciones.pedido WHERE codigo_pedido = p_codigo_pedido FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe', p_codigo_pedido;
    END IF;
    IF v_estado <> 'Pendiente' THEN
        RAISE EXCEPTION 'Solo se pueden rechazar pedidos Pendientes (estado actual: %)', v_estado;
    END IF;

    UPDATE operaciones.pedido
    SET estado = 'Rechazado',
        comentarios = concat_ws(E'\n', comentarios, 'Rechazado: ' || p_motivo)
    WHERE codigo_pedido = p_codigo_pedido;
END $$;

-- Registra un pago contra un pedido (no puede superar el saldo)
CREATE OR REPLACE PROCEDURE operaciones.sp_registrar_pago(
    p_codigo_cliente INTEGER,
    p_codigo_pedido  INTEGER,
    p_total          NUMERIC,
    p_forma_pago     TEXT,
    INOUT p_id_transaccion TEXT DEFAULT NULL)
LANGUAGE plpgsql AS $$
DECLARE
    v_estado TEXT;
    v_saldo  NUMERIC;
BEGIN
    SELECT estado INTO v_estado
    FROM operaciones.pedido
    WHERE codigo_pedido = p_codigo_pedido AND codigo_cliente = p_codigo_cliente
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El pedido % no existe o no pertenece al cliente %',
                        p_codigo_pedido, p_codigo_cliente;
    END IF;
    IF v_estado = 'Rechazado' THEN
        RAISE EXCEPTION 'No se puede pagar un pedido Rechazado';
    END IF;
    IF p_total IS NULL OR p_total <= 0 THEN
        RAISE EXCEPTION 'El monto debe ser mayor que cero';
    END IF;

    v_saldo := operaciones.fn_saldo_pedido(p_codigo_pedido);
    IF p_total > v_saldo THEN
        RAISE EXCEPTION 'El pago (%) supera el saldo del pedido (%)', p_total, v_saldo;
    END IF;

    p_id_transaccion := COALESCE(NULLIF(p_id_transaccion, ''),
                                 'tx-' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 12));

    INSERT INTO operaciones.pago
           (codigo_cliente, id_transaccion, codigo_pedido, forma_pago, total)
    VALUES (p_codigo_cliente, p_id_transaccion, p_codigo_pedido, p_forma_pago, p_total);
END $$;

-- Reposición de inventario
CREATE OR REPLACE PROCEDURE operaciones.sp_reponer_stock(
    p_codigo_producto VARCHAR,
    p_cantidad        INTEGER)
LANGUAGE plpgsql AS $$
BEGIN
    IF p_cantidad IS NULL OR p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a reponer debe ser mayor que cero';
    END IF;

    UPDATE operaciones.producto
    SET cantidad_en_stock = cantidad_en_stock + p_cantidad
    WHERE codigo_producto = p_codigo_producto;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El producto % no existe', p_codigo_producto;
    END IF;
END $$;
