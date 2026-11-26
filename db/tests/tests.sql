-- tests.sql : pruebas de la lógica en la BD.
-- Todo corre dentro de una transacción que termina en ROLLBACK: no deja datos.
-- Uso:  docker exec -i jardineria_db psql -U admin -d jardineria < db/tests/tests.sql
\set ON_ERROR_STOP on
\pset format aligned
\pset footer off

BEGIN;
SELECT set_config('app.user', 'tester', true) AS usuario_app;

CREATE TEMP TABLE resultado (n SERIAL, prueba TEXT, ok BOOLEAN);

CREATE FUNCTION pg_temp.t(p_prueba TEXT, p_ok BOOLEAN) RETURNS VOID
LANGUAGE sql AS $$ INSERT INTO resultado (prueba, ok) VALUES (p_prueba, COALESCE(p_ok, FALSE)) $$;

-- Ejecuta p_sql y espera que falle con un mensaje que contenga p_fragmento
CREATE FUNCTION pg_temp.falla(p_prueba TEXT, p_sql TEXT, p_fragmento TEXT) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE p_sql;
        PERFORM pg_temp.t(p_prueba, FALSE);                       -- debía fallar y no falló
    EXCEPTION WHEN OTHERS THEN
        PERFORM pg_temp.t(p_prueba, position(p_fragmento IN SQLERRM) > 0);
    END;
END $$;

DO $$
DECLARE
    v_cli   INTEGER := 4;      -- cliente con crédito disponible
    v_prod  TEXT;
    v_stock0 INTEGER; v_precio NUMERIC;
    v_ped1  INTEGER; v_ped2 INTEGER;
    v_total NUMERIC; v_pago NUMERIC; v_tx TEXT;
    v_linea JSONB; v_n INTEGER;
BEGIN
    SELECT codigo_producto, cantidad_en_stock, precio_venta INTO v_prod, v_stock0, v_precio
    FROM operaciones.producto WHERE activo AND cantidad_en_stock >= 20
    ORDER BY codigo_producto LIMIT 1;

    -- ===== 1. Pedido válido =====
    v_linea := jsonb_build_array(jsonb_build_object('codigo_producto', v_prod, 'cantidad', 3));
    CALL operaciones.sp_crear_pedido(v_cli, CURRENT_DATE + 7, 'test', v_linea, v_ped1);
    SELECT total INTO v_total FROM operaciones.pedido WHERE codigo_pedido = v_ped1;
    PERFORM pg_temp.t('crear pedido: devuelve código', v_ped1 IS NOT NULL);
    PERFORM pg_temp.t('crear pedido: total = 3 x precio', v_total = 3 * v_precio);
    PERFORM pg_temp.t('crear pedido: estado Pendiente',
        (SELECT estado FROM operaciones.pedido WHERE codigo_pedido = v_ped1) = 'Pendiente');
    PERFORM pg_temp.t('crear pedido: descuenta stock',
        (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 3);
    PERFORM pg_temp.t('auditoría: registra al usuario real de la app',
        EXISTS (SELECT 1 FROM auditoria.log
                WHERE tabla = 'pedido' AND operacion = 'INSERT' AND usuario_app = 'tester'
                  AND (datos_new->>'codigo_pedido')::INTEGER = v_ped1));

    -- ===== 2. Líneas repetidas se agrupan =====
    v_linea := jsonb_build_array(jsonb_build_object('codigo_producto', v_prod, 'cantidad', 1),
                                 jsonb_build_object('codigo_producto', v_prod, 'cantidad', 2));
    CALL operaciones.sp_crear_pedido(v_cli, CURRENT_DATE + 7, 'test2', v_linea, v_ped2);
    SELECT COUNT(*) INTO v_n FROM operaciones.detalle_pedido
    WHERE codigo_pedido = v_ped2 AND cantidad = 3 AND numero_linea = 1;
    PERFORM pg_temp.t('líneas repetidas: una sola línea con la suma', v_n = 1);
    PERFORM pg_temp.t('stock acumulado tras 2 pedidos',
        (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 6);

    -- ===== 3. Fallos que deben revertir todo =====
    PERFORM pg_temp.falla('stock insuficiente: rechaza',
        format('CALL operaciones.sp_crear_pedido(%s, CURRENT_DATE + 7, %L, %L::jsonb, NULL)', v_cli, 'x',
               jsonb_build_array(jsonb_build_object('codigo_producto', v_prod, 'cantidad', 100000))::TEXT),
        'Stock insuficiente');
    PERFORM pg_temp.t('stock insuficiente: no queda pedido a medias',
        NOT EXISTS (SELECT 1 FROM operaciones.pedido WHERE comentarios = 'x'));
    PERFORM pg_temp.t('stock insuficiente: stock intacto',
        (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 6);

    PERFORM pg_temp.falla('crédito insuficiente: rechaza',
        format('CALL operaciones.sp_crear_pedido(1, CURRENT_DATE + 7, %L, %L::jsonb, NULL)', 'y',
               jsonb_build_array(jsonb_build_object('codigo_producto', v_prod, 'cantidad', 1))::TEXT),
        'Crédito insuficiente');
    PERFORM pg_temp.t('crédito insuficiente: no queda pedido ni stock descontado',
        NOT EXISTS (SELECT 1 FROM operaciones.pedido WHERE comentarios = 'y')
        AND (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 6);

    PERFORM pg_temp.falla('producto inexistente',
        format('CALL operaciones.sp_crear_pedido(%s, CURRENT_DATE + 7, NULL, %L::jsonb, NULL)', v_cli,
               '[{"codigo_producto":"NO-EXISTE","cantidad":1}]'),
        'no existe o está inactivo');
    PERFORM pg_temp.falla('pedido sin líneas',
        format('CALL operaciones.sp_crear_pedido(%s, CURRENT_DATE + 7, NULL, ''[]''::jsonb, NULL)', v_cli),
        'al menos una línea');
    PERFORM pg_temp.falla('fecha esperada en el pasado',
        format('CALL operaciones.sp_crear_pedido(%s, CURRENT_DATE - 1, NULL, %L::jsonb, NULL)', v_cli,
               v_linea::TEXT),
        'fecha esperada');
    PERFORM pg_temp.falla('cliente inexistente',
        format('CALL operaciones.sp_crear_pedido(99999, CURRENT_DATE + 7, NULL, %L::jsonb, NULL)', v_linea::TEXT),
        'no existe o está inactivo');

    -- ===== 4. Rechazar devuelve stock; máquina de estados =====
    CALL operaciones.sp_rechazar_pedido(v_ped2, 'prueba');
    PERFORM pg_temp.t('rechazar: estado Rechazado y motivo en comentarios',
        (SELECT estado = 'Rechazado' AND comentarios LIKE '%Rechazado: prueba%'
         FROM operaciones.pedido WHERE codigo_pedido = v_ped2));
    PERFORM pg_temp.t('rechazar: devuelve el stock',
        (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 3);
    PERFORM pg_temp.falla('rechazado no se puede entregar',
        format('CALL operaciones.sp_entregar_pedido(%s)', v_ped2), 'Solo se pueden entregar');
    PERFORM pg_temp.falla('transición Rechazado -> Entregado bloqueada por trigger',
        format('UPDATE operaciones.pedido SET estado = ''Entregado'', fecha_entrega = CURRENT_DATE WHERE codigo_pedido = %s', v_ped2),
        'Transición de estado no permitida');
    PERFORM pg_temp.falla('rechazo exige motivo',
        format('CALL operaciones.sp_rechazar_pedido(%s, '' '')', v_ped1), 'motivo');

    -- ===== 5. Pagos =====
    v_pago := round(v_total / 2, 2);
    CALL operaciones.sp_registrar_pago(v_cli, v_ped1, v_pago, 'Transferencia', v_tx);
    PERFORM pg_temp.t('pago parcial: devuelve id de transacción', v_tx IS NOT NULL);
    PERFORM pg_temp.t('pago parcial: saldo = total - pago',
        operaciones.fn_saldo_pedido(v_ped1) = v_total - v_pago);
    PERFORM pg_temp.falla('sobrepago rechazado',
        format('CALL operaciones.sp_registrar_pago(%s, %s, %s, ''PayPal'', NULL)', v_cli, v_ped1, v_total),
        'supera el saldo');
    PERFORM pg_temp.falla('pago a pedido Rechazado',
        format('CALL operaciones.sp_registrar_pago(%s, %s, 1, ''PayPal'', NULL)', v_cli, v_ped2),
        'Rechazado');
    PERFORM pg_temp.falla('pago de otro cliente',
        format('CALL operaciones.sp_registrar_pago(1, %s, 1, ''PayPal'', NULL)', v_ped1),
        'no pertenece');
    PERFORM pg_temp.falla('forma de pago inválida',
        format('CALL operaciones.sp_registrar_pago(%s, %s, 1, ''Bitcoin'', NULL)', v_cli, v_ped1),
        'pago_forma_pago_check');
    PERFORM pg_temp.falla('monto cero',
        format('CALL operaciones.sp_registrar_pago(%s, %s, 0, ''PayPal'', NULL)', v_cli, v_ped1),
        'mayor que cero');
    PERFORM pg_temp.falla('id de transacción repetido',
        format('CALL operaciones.sp_registrar_pago(%s, %s, 1, ''PayPal'', %L)', v_cli, v_ped1, v_tx),
        'pago_pkey');
    v_tx := NULL;   -- el INOUT vuelve a generarse solo
    CALL operaciones.sp_registrar_pago(v_cli, v_ped1, v_total - v_pago, 'PayPal', v_tx);
    PERFORM pg_temp.t('pago final: saldo 0', operaciones.fn_saldo_pedido(v_ped1) = 0);

    -- ===== 6. Entregar =====
    CALL operaciones.sp_entregar_pedido(v_ped1);
    PERFORM pg_temp.t('entregar: estado Entregado con fecha_entrega',
        (SELECT estado = 'Entregado' AND fecha_entrega = CURRENT_DATE
         FROM operaciones.pedido WHERE codigo_pedido = v_ped1));
    PERFORM pg_temp.falla('entregar dos veces',
        format('CALL operaciones.sp_entregar_pedido(%s)', v_ped1), 'Solo se pueden entregar');
    PERFORM pg_temp.falla('rechazar un pedido entregado',
        format('CALL operaciones.sp_rechazar_pedido(%s, ''x'')', v_ped1), 'Solo se pueden rechazar');
    PERFORM pg_temp.falla('no se agregan líneas a pedido entregado',
        format('INSERT INTO operaciones.detalle_pedido VALUES (%s, %L, 1, 1, 9)', v_ped1, v_prod),
        'Solo se pueden agregar líneas');

    -- ===== 7. Historial inmutable =====
    PERFORM pg_temp.falla('línea: UPDATE bloqueado',
        format('UPDATE operaciones.detalle_pedido SET cantidad = 99 WHERE codigo_pedido = %s', v_ped1),
        'no se pueden modificar');
    PERFORM pg_temp.falla('línea: DELETE bloqueado',
        format('DELETE FROM operaciones.detalle_pedido WHERE codigo_pedido = %s', v_ped1),
        'no se pueden modificar');
    PERFORM pg_temp.falla('pedido: DELETE bloqueado',
        format('DELETE FROM operaciones.pedido WHERE codigo_pedido = %s', v_ped1),
        'No se permite borrar');
    PERFORM pg_temp.falla('pago: DELETE bloqueado',
        'DELETE FROM operaciones.pago', 'No se permite borrar');

    -- ===== 8. Inventario =====
    CALL operaciones.sp_reponer_stock(v_prod, 10);
    PERFORM pg_temp.t('reponer stock suma',
        (SELECT cantidad_en_stock FROM operaciones.producto WHERE codigo_producto = v_prod) = v_stock0 - 3 + 10);
    PERFORM pg_temp.falla('reponer cantidad 0',
        format('CALL operaciones.sp_reponer_stock(%L, 0)', v_prod), 'mayor que cero');
    PERFORM pg_temp.falla('reponer producto inexistente',
        'CALL operaciones.sp_reponer_stock(''NO-EXISTE'', 5)', 'no existe');

    -- ===== 9. Restricciones declarativas =====
    PERFORM pg_temp.falla('CHECK: Pendiente con fecha_entrega',
        format('INSERT INTO operaciones.pedido (fecha_esperada, fecha_entrega, codigo_cliente) VALUES (CURRENT_DATE + 1, CURRENT_DATE, %s)', v_cli),
        'ck_entrega_estado');
    PERFORM pg_temp.falla('CHECK: fecha_esperada anterior al pedido',
        format('INSERT INTO operaciones.pedido (fecha_pedido, fecha_esperada, codigo_cliente) VALUES (CURRENT_DATE, CURRENT_DATE - 5, %s)', v_cli),
        'ck_fechas');
    PERFORM pg_temp.falla('FK compuesta: pago con pedido de otro cliente',
        format('INSERT INTO operaciones.pago (codigo_cliente, id_transaccion, codigo_pedido, forma_pago, total) VALUES (1, ''zz'', %s, ''PayPal'', 1)', v_ped1),
        'fk_pago_pedido');
    PERFORM pg_temp.falla('UNIQUE: cliente duplicado',
        'INSERT INTO clientes.cliente (nombre_cliente, telefono, linea_direccion1, ciudad) SELECT nombre_cliente, telefono, ''x'', ''x'' FROM clientes.cliente LIMIT 1',
        'cliente_nombre_cliente_telefono_key');

    -- ===== 10. Auditoría y funciones =====
    UPDATE seguridad.usuario SET activo = TRUE WHERE usuario = 'admin';
    PERFORM pg_temp.t('auditoría: password_hash no se registra',
        EXISTS (SELECT 1 FROM auditoria.log WHERE tabla = 'usuario' AND operacion = 'UPDATE')
        AND NOT EXISTS (SELECT 1 FROM auditoria.log
                        WHERE tabla = 'usuario' AND (datos_new ? 'password_hash' OR datos_old ? 'password_hash')));
    PERFORM pg_temp.t('fn_ingresos_periodo = suma directa de pagos 2008',
        operaciones.fn_ingresos_periodo('2008-01-01', '2008-12-31')
        = (SELECT SUM(total) FROM operaciones.pago WHERE fecha_pago BETWEEN '2008-01-01' AND '2008-12-31'));
    PERFORM pg_temp.t('fn_credito_disponible: cliente inexistente = NULL',
        operaciones.fn_credito_disponible(99999) IS NULL);
    PERFORM pg_temp.t('datos migrados: ningún pedido con total 0',
        NOT EXISTS (SELECT 1 FROM operaciones.pedido WHERE total = 0 AND comentarios IS DISTINCT FROM 'test'
                                                          AND comentarios IS DISTINCT FROM 'test2'));
END $$;

SELECT n, prueba, CASE WHEN ok THEN 'PASS' ELSE 'FAIL' END AS resultado FROM resultado ORDER BY n;
SELECT count(*) AS pruebas, count(*) FILTER (WHERE ok) AS pasan, count(*) FILTER (WHERE NOT ok) AS fallan FROM resultado;

ROLLBACK;
