-- 04_triggers.sql

-- =========================================================
-- Auditoría: una sola función para todas las tablas.
-- SECURITY DEFINER: app_user no necesita permisos sobre auditoria.log.
-- El usuario real de la aplicación llega por set_config('app.user', ..., true).
-- =========================================================
CREATE OR REPLACE FUNCTION auditoria.fn_log()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp AS $$
DECLARE
    v_old JSONB;
    v_new JSONB;
BEGIN
    IF TG_OP <> 'INSERT' THEN v_old := to_jsonb(OLD) - 'password_hash'; END IF;
    IF TG_OP <> 'DELETE' THEN v_new := to_jsonb(NEW) - 'password_hash'; END IF;

    INSERT INTO auditoria.log (esquema, tabla, operacion, usuario_app, usuario_bd, fecha, datos_old, datos_new)
    VALUES (TG_TABLE_SCHEMA, TG_TABLE_NAME, TG_OP,
            COALESCE(NULLIF(current_setting('app.user', true), ''), 'sistema'),
            session_user, now(), v_old, v_new);
    RETURN NULL;
END $$;

-- =========================================================
-- detalle_pedido: validar estado del pedido y descontar stock (atómico)
-- =========================================================
CREATE OR REPLACE FUNCTION operaciones.fn_detalle_before_insert()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_estado TEXT;
BEGIN
    SELECT estado INTO v_estado
    FROM operaciones.pedido WHERE codigo_pedido = NEW.codigo_pedido;
    IF v_estado IS DISTINCT FROM 'Pendiente' THEN
        RAISE EXCEPTION 'Solo se pueden agregar líneas a pedidos Pendientes';
    END IF;

    UPDATE operaciones.producto
    SET cantidad_en_stock = cantidad_en_stock - NEW.cantidad
    WHERE codigo_producto = NEW.codigo_producto
      AND cantidad_en_stock >= NEW.cantidad;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Stock insuficiente para el producto %', NEW.codigo_producto;
    END IF;

    RETURN NEW;
END $$;

CREATE TRIGGER trg_detalle_stock
BEFORE INSERT ON operaciones.detalle_pedido
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_detalle_before_insert();

-- Las líneas son insert-only (mantiene coherentes stock y total)
CREATE OR REPLACE FUNCTION operaciones.fn_detalle_inmutable()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Las líneas de un pedido no se pueden modificar ni eliminar';
END $$;

CREATE TRIGGER trg_detalle_inmutable
BEFORE UPDATE OR DELETE ON operaciones.detalle_pedido
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_detalle_inmutable();

-- Recalcula pedido.total al insertar una línea
CREATE OR REPLACE FUNCTION operaciones.fn_detalle_after_insert()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE operaciones.pedido
    SET total = operaciones.fn_total_pedido(NEW.codigo_pedido)
    WHERE codigo_pedido = NEW.codigo_pedido;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_detalle_total
AFTER INSERT ON operaciones.detalle_pedido
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_detalle_after_insert();

-- =========================================================
-- pedido: máquina de estados y devolución de stock al rechazar
-- =========================================================
CREATE OR REPLACE FUNCTION operaciones.fn_pedido_validar_estado()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.estado IS DISTINCT FROM OLD.estado
       AND NOT (OLD.estado = 'Pendiente' AND NEW.estado IN ('Entregado', 'Rechazado')) THEN
        RAISE EXCEPTION 'Transición de estado no permitida: % -> %', OLD.estado, NEW.estado;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_pedido_estado
BEFORE UPDATE OF estado ON operaciones.pedido
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_pedido_validar_estado();

CREATE OR REPLACE FUNCTION operaciones.fn_pedido_devolver_stock()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE operaciones.producto p
    SET cantidad_en_stock = p.cantidad_en_stock + d.cantidad
    FROM operaciones.detalle_pedido d
    WHERE d.codigo_pedido = NEW.codigo_pedido
      AND d.codigo_producto = p.codigo_producto;
    RETURN NULL;
END $$;

CREATE TRIGGER trg_pedido_rechazo_stock
AFTER UPDATE OF estado ON operaciones.pedido
FOR EACH ROW
WHEN (OLD.estado = 'Pendiente' AND NEW.estado = 'Rechazado')
EXECUTE FUNCTION operaciones.fn_pedido_devolver_stock();

-- Pedidos y pagos son historial: no se borran
CREATE OR REPLACE FUNCTION operaciones.fn_bloquear_borrado()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'No se permite borrar registros de %: se conserva el historial', TG_TABLE_NAME;
END $$;

CREATE TRIGGER trg_pedido_no_borrar
BEFORE DELETE ON operaciones.pedido
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_bloquear_borrado();

CREATE TRIGGER trg_pago_no_borrar
BEFORE DELETE ON operaciones.pago
FOR EACH ROW EXECUTE FUNCTION operaciones.fn_bloquear_borrado();

-- =========================================================
-- Auditoría en todas las tablas de negocio
-- =========================================================
DO $$
DECLARE
    t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'operaciones.oficina', 'operaciones.empleado', 'operaciones.gama_producto',
        'operaciones.proveedor', 'operaciones.producto', 'clientes.cliente',
        'operaciones.pedido', 'operaciones.detalle_pedido', 'operaciones.pago',
        'seguridad.usuario']
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_auditoria AFTER INSERT OR UPDATE OR DELETE ON %s
             FOR EACH ROW EXECUTE FUNCTION auditoria.fn_log()', t);
    END LOOP;
END $$;
