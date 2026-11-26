# Sistema de Gestión de Jardinería

Aplicación web distribuida para la gestión integral de clientes, pedidos, pagos, catálogos, reportes y auditoría, desplegada sobre Docker Compose con PostgreSQL 16, microservicios FastAPI, frontend en Streamlit y proxy inverso Caddy con TLS automático (Let's Encrypt).

## Arquitectura

- **Base de datos:** PostgreSQL 16 (`jardineria_db`) con funciones, procedimientos almacenados, triggers de auditoría, vistas, roles dedicados y pruebas de integridad SQL.
- **Microservicios (FastAPI):**
  - `clientes`: Gestión de clientes, oficinas y empleados.
  - `operaciones`: Pedidos, detalle de pedidos, pagos y control de crédito/stock.
  - `reportes`: Consultas analíticas, métricas de ventas y auditoría.
- **API Gateway:** Nginx como enrutador interno (`/api/clientes`, `/api/operaciones`, `/api/reportes`, `/app`).
- **Frontend:** Interfaz web interactiva construida con Streamlit.
- **Reverse Proxy & SSL:** Caddy con emisión y renovación automática de certificados TLS mediante Let's Encrypt.

## Estructura del Proyecto

```text
├── db/                 # Esquemas, funciones, procedimientos, triggers, vistas y pruebas SQL
├── services/           # Microservicios FastAPI (clientes, operaciones, reportes) y gateway Nginx
├── frontend/           # Aplicación web Streamlit
├── scripts/            # Automatización de backups, restauración y checklist de validación
├── docs/               # Documentación técnica (MER, diccionario de datos y requisitos)
├── Caddyfile           # Configuración de proxy inverso y HTTPS
└── docker-compose.yml  # Orquestación de contenedores
```

## Despliegue Rápido

1. Clonar el repositorio y configurar variables de entorno:
   ```bash
   cp .env.example .env
   # Editar .env con credenciales seguras, JWT_SECRET y DOMAIN
   ```
2. Levantar los servicios:
   ```bash
   docker compose up -d --build
   ```
3. Ejecutar la suite de validación:
   ```bash
   CHECK_USER=admin CHECK_PASS='TuPassword' RUN_TESTS=1 ./scripts/checklist.sh
   ```