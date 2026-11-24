-- ============================================================================
-- PROYECTO: MASTER DATA MANAGEMENT (MDM) - EXPLORACIÓN, LIMPIEZA Y GOLDEN RECORD
-- MOTOR: PostgreSQL
-- TABLAS ORIGEN: erp_customers, crm_customers, marketing_leads, weekly_issues
-- ============================================================================


-- ============================================================================
-- FASE 1: EXPLORACIÓN DE ESQUEMA Y MUESTREO INICIAL
-- ============================================================================

-- 1A. Inspección de estructura, columnas y tipos de datos de las 4 tablas
SELECT 
    table_name, 
    column_name, 
    data_type,
    LENGTH(column_name) AS longitud_nombre
FROM information_schema.columns
WHERE table_name IN ('erp_customers', 'crm_customers', 'marketing_leads', 'weekly_issues')
ORDER BY table_name, ordinal_position;

-- 1B. Muestreo rápido de datos crudos (Primeras 20 filas)
SELECT * FROM crm_customers LIMIT 20;
SELECT * FROM erp_customers LIMIT 20;
SELECT * FROM marketing_leads LIMIT 20;
SELECT * FROM weekly_issues LIMIT 20;


-- ============================================================================
-- FASE 2: PERFILAMIENTO DE DATOS (DATA PROFILING) Y CALIDAD DE LLAVES
-- ============================================================================

-- 2A. Volumen total, llaves únicas y vacíos reales por tabla
SELECT 
    'erp_customers' AS tabla,
    COUNT(*) AS total_filas,
    COUNT(DISTINCT NULLIF(TRIM(customer_no), '')) AS ids_unicos,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(customer_no), '') IS NULL) AS ids_vacios,
    COUNT(DISTINCT LOWER(NULLIF(TRIM(email), ''))) AS emails_unicos,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(email), '') IS NULL) AS emails_vacios
FROM erp_customers

UNION ALL

SELECT 
    'crm_customers',
    COUNT(*),
    COUNT(DISTINCT NULLIF(TRIM("contact_id"), '')),
    COUNT(*) FILTER (WHERE NULLIF(TRIM("contact_id"), '') IS NULL),
    COUNT(DISTINCT LOWER(NULLIF(TRIM("email"), ''))),
    COUNT(*) FILTER (WHERE NULLIF(TRIM("email"), '') IS NULL)
FROM crm_customers

UNION ALL

SELECT 
    'marketing_leads',
    COUNT(*),
    COUNT(DISTINCT NULLIF(TRIM(lead_id), '')),
    COUNT(*) FILTER (WHERE NULLIF(TRIM(lead_id), '') IS NULL),
    COUNT(DISTINCT LOWER(NULLIF(TRIM(email), ''))),
    COUNT(*) FILTER (WHERE NULLIF(TRIM(email), '') IS NULL)
FROM marketing_leads

UNION ALL

SELECT 
    'weekly_issues',
    COUNT(*),
    COUNT(DISTINCT week || '-' || source || '-' || issue_type),
    0,
    NULL,
    NULL
FROM weekly_issues;

-- 2B. Detección de valores atípicos en catálogos (Ejemplo: variaciones de Estado)
SELECT 'CRM' AS fuente, COALESCE(NULLIF(TRIM("state"), ''), '[VACÍO]') AS valor_estado, COUNT(*) AS frecuencia
FROM crm_customers GROUP BY 2
UNION ALL
SELECT 'ERP', COALESCE(NULLIF(TRIM(estado), ''), '[VACÍO]'), COUNT(*)
FROM erp_customers GROUP BY 2
ORDER BY fuente, frecuencia DESC;


-- ============================================================================
-- FASE 3: PRUEBAS DE INTEGRIDAD, DUPLICADOS INTERNOS Y NULOS DISFRAZADOS
-- ============================================================================

-- 3A. Prueba de cruce por IDs internos (Demuestra 0 coincidencias entre sistemas)
SELECT 
    CASE 
        WHEN e.customer_no IS NOT NULL AND c."contact_id" IS NOT NULL THEN 'En ambos (ERP y CRM)'
        WHEN e.customer_no IS NOT NULL THEN 'Solo en ERP'
        ELSE 'Solo en CRM'
    END AS estado_cruce_id,
    COUNT(*) AS cantidad_registros
FROM erp_customers e
FULL OUTER JOIN crm_customers c 
    ON NULLIF(TRIM(e.customer_no), '') = NULLIF(TRIM(c."contact_id"), '')
GROUP BY 1;

-- 3B. [CORREGIDO] Detección de duplicados internos reales (excluyendo textos basura)
SELECT 'ERP' AS origen, LOWER(TRIM(email)) AS email_crudo, COUNT(*) AS repeticiones
FROM erp_customers
WHERE NULLIF(TRIM(email), '') IS NOT NULL
  AND LOWER(TRIM(email)) NOT IN ('n/a', 'na', 'null', '-', 'none', 'sin correo')
  AND email LIKE '%@%'
GROUP BY 2 HAVING COUNT(*) > 1

UNION ALL

SELECT 'CRM', LOWER(TRIM("email")), COUNT(*)
FROM crm_customers
WHERE NULLIF(TRIM("email"), '') IS NOT NULL
  AND LOWER(TRIM("email")) NOT IN ('n/a', 'na', 'null', '-', 'none', 'sin correo')
  AND "email" LIKE '%@%'
GROUP BY 2 HAVING COUNT(*) > 1
ORDER BY origen, repeticiones DESC;

-- 3C. Inspección de caso testigo duplicado (Sofía Molina)
SELECT 'CRM' AS fuente, "contact_id", "first_name", "last_name", "email", "phone", "state", "updated_at"
FROM crm_customers WHERE LOWER(TRIM("email")) = 'sofia_molina@vidriosyaluminio.com';

-- 3D. Auditoría de registros sin email válido rescatables por Teléfono (10 dígitos) o RFC
SELECT 
    'ERP sin email' AS grupo,
    COUNT(*) AS total_registros,
    COUNT(*) FILTER (WHERE LENGTH(REGEXP_REPLACE(telefono, '[^0-9]', '', 'g')) >= 10) AS rescatables_por_telefono,
    COUNT(*) FILTER (WHERE NULLIF(TRIM(rfc), '') IS NOT NULL) AS rescatables_por_rfc
FROM erp_customers
WHERE LOWER(TRIM(email)) IN ('', 'n/a', 'na', 'null', '-', 'none', 'sin correo') 
   OR email NOT LIKE '%@%' OR email IS NULL

UNION ALL

SELECT 
    'CRM sin email',
    COUNT(*),
    COUNT(*) FILTER (WHERE LENGTH(REGEXP_REPLACE("phone", '[^0-9]', '', 'g')) >= 10),
    0
FROM crm_customers
WHERE LOWER(TRIM("email")) IN ('', 'n/a', 'na', 'null', '-', 'none', 'sin correo') 
   OR "email" NOT LIKE '%@%' OR "email" IS NULL;


-- ============================================================================
-- FASE 4: CAPA STAGING (ESTANDARIZACIÓN Y DEDUPLICACIÓN SIN ALTERAR CRUDOS)
-- ============================================================================

-- Reinicio seguro de vistas antes de reconstruir
DROP VIEW IF EXISTS mdm_leads_enriquecidos CASCADE;
DROP VIEW IF EXISTS mdm_golden_customers CASCADE;
DROP VIEW IF EXISTS stg_crm_customers CASCADE;
DROP VIEW IF EXISTS stg_erp_customers CASCADE;

-- 4A. Vista Staging CRM (Limpieza + Llave Jerárquica + Deduplicación por updated_at)
CREATE VIEW stg_crm_customers AS
WITH cleaned AS (
    SELECT 
        "contact_id",
        TRIM("first_name") || ' ' || TRIM("last_name") AS full_name,
        NULLIF(TRIM("company"), '') AS company,
        CASE 
            WHEN LOWER(TRIM("email")) IN ('', 'n/a', 'na', 'null', '-', 'none', 'sin correo') 
                 OR "email" NOT LIKE '%@%' THEN NULL
            ELSE LOWER(TRIM("email"))
        END AS clean_email,
        NULLIF(RIGHT(REGEXP_REPLACE("phone", '[^0-9]', '', 'g'), 10), '') AS clean_phone,
        TRIM("street") AS street,
        TRIM("city") AS city,
        CASE 
            WHEN LOWER(TRIM("state")) IN ('q.r.', 'qr', 'quintana roo') THEN 'Quintana Roo'
            ELSE INITCAP(TRIM("state"))
        END AS clean_state,
        TRIM("postal_code") AS postal_code,
        "updated_at"
    FROM crm_customers
),
with_key AS (
    SELECT *,
        COALESCE(
            clean_email, 
            CASE WHEN LENGTH(clean_phone) = 10 THEN 'TEL_' || clean_phone ELSE NULL END
        ) AS match_key
    FROM cleaned
),
deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY match_key 
            ORDER BY "updated_at" DESC NULLS LAST, "contact_id" DESC
        ) AS rn
    FROM with_key
    WHERE match_key IS NOT NULL
)
SELECT * FROM deduplicated WHERE rn = 1;

-- 4B. Vista Staging ERP (Homologación de esquema + Deduplicación por last_invoice_date)
CREATE VIEW stg_erp_customers AS
WITH cleaned AS (
    SELECT 
        customer_no,
        UPPER(TRIM(rfc)) AS clean_rfc,
        NULLIF(TRIM(razon_social), '') AS razon_social,
        NULLIF(TRIM(contact_name), '') AS contact_name,
        CASE 
            WHEN LOWER(TRIM(email)) IN ('', 'n/a', 'na', 'null', '-', 'none', 'sin correo') 
                 OR email NOT LIKE '%@%' THEN NULL
            ELSE LOWER(TRIM(email))
        END AS clean_email,
        NULLIF(RIGHT(REGEXP_REPLACE(telefono, '[^0-9]', '', 'g'), 10), '') AS clean_phone,
        TRIM(direccion) AS direccion,
        TRIM(ciudad) AS ciudad,
        CASE 
            WHEN LOWER(TRIM(estado)) IN ('q.r.', 'qr', 'quintana roo') THEN 'Quintana Roo'
            ELSE INITCAP(TRIM(estado))
        END AS clean_state,
        TRIM(cp) AS cp,
        -- [CORREGIDO] Normaliza comas decimales (ej. 15000,00 -> 15000.00) antes de limpiar caracteres
        COALESCE(
            NULLIF(
                REGEXP_REPLACE(
                    CASE 
                        WHEN TRIM(credit_limit) ~ ',\d{1,2}$' 
                            THEN REPLACE(REPLACE(TRIM(credit_limit), '.', ''), ',', '.')
                        ELSE REPLACE(TRIM(credit_limit), ',', '')
                    END,
                    '[^0-9.]', '', 'g'
                ),
                ''
            )::NUMERIC,
            0
        ) AS clean_credit_limit,
        currency,
        status,
        last_invoice_date
    FROM erp_customers
),
with_key AS (
    SELECT *,
        COALESCE(
            clean_email, 
            CASE WHEN LENGTH(clean_phone) = 10 THEN 'TEL_' || clean_phone ELSE NULL END
        ) AS match_key
    FROM cleaned
),
deduplicated AS (
    SELECT *,
        ROW_NUMBER() OVER (
            PARTITION BY match_key 
            ORDER BY last_invoice_date DESC NULLS LAST, clean_rfc DESC NULLS LAST, customer_no DESC
        ) AS rn
    FROM with_key
    WHERE match_key IS NOT NULL
)
SELECT * FROM deduplicated WHERE rn = 1;


-- ============================================================================
-- FASE 5: CONSTRUCCIÓN DEL GOLDEN RECORD Y ENRIQUECIMIENTO DE LEADS
-- ============================================================================

-- 5A. Tabla Maestra de Clientes (1,172 registros únicos unificados)
CREATE VIEW mdm_golden_customers AS
SELECT 
    ROW_NUMBER() OVER (ORDER BY COALESCE(e.match_key, c.match_key)) AS mdm_customer_id,
    e.customer_no AS erp_id,
    c."contact_id" AS crm_id,
    CASE 
        WHEN e.match_key IS NOT NULL AND c.match_key IS NOT NULL THEN 'ERP + CRM'
        WHEN e.match_key IS NOT NULL THEN 'Solo ERP'
        ELSE 'Solo CRM'
    END AS origen_dato,
    CASE 
        WHEN COALESCE(e.match_key, c.match_key) LIKE 'TEL_%' THEN 'Teléfono (Rescatado)'
        ELSE 'Email'
    END AS metodo_cruce,
    COALESCE(e.clean_email, c.clean_email) AS email,
    COALESCE(c.full_name, e.contact_name) AS nombre_contacto,
    COALESCE(e.razon_social, c.company) AS empresa_razon_social,
    e.clean_rfc AS rfc,
    COALESCE(NULLIF(c.clean_phone, ''), e.clean_phone) AS telefono_10_dig,
    COALESCE(c.street, e.direccion) AS direccion,
    COALESCE(c.city, e.ciudad) AS ciudad,
    COALESCE(c.clean_state, e.clean_state) AS estado,
    COALESCE(c.postal_code, e.cp) AS codigo_postal,
    COALESCE(e.clean_credit_limit, 0) AS limite_credito,
    COALESCE(e.currency, 'MXN') AS moneda,
    COALESCE(e.status, 'Prospecto CRM') AS estatus_cuenta
FROM stg_erp_customers e
FULL OUTER JOIN stg_crm_customers c 
    ON e.match_key = c.match_key;

-- 5B. [CORREGIDO] Enriquecimiento de Marketing Leads (510 registros exactos, sin duplicados por teléfono compartido)
CREATE VIEW mdm_leads_enriquecidos AS
WITH leads_clean AS (
    SELECT 
        lead_id,
        TRIM(full_name) AS clean_name,
        CASE 
            WHEN LOWER(TRIM(email)) IN ('', 'n/a', 'na', 'null', '-', 'none', 'sin correo') 
                 OR email NOT LIKE '%@%' THEN NULL
            ELSE LOWER(TRIM(email))
        END AS clean_email,
        NULLIF(RIGHT(REGEXP_REPLACE(phone, '[^0-9]', '', 'g'), 10), '') AS clean_phone,
        signup_date,
        utm_source,
        country
    FROM marketing_leads
)
SELECT 
    l.lead_id,
    l.clean_name,
    l.clean_email,
    l.clean_phone,
    l.signup_date,
    l.utm_source,
    l.country,
    g.mdm_customer_id,
    CASE 
        WHEN g.mdm_customer_id IS NOT NULL THEN 'Ya es Cliente (' || g.origen_dato || ')'
        ELSE 'Prospecto Nuevo (No en ERP/CRM)'
    END AS estatus_mdm
FROM leads_clean l
LEFT JOIN LATERAL (
    SELECT mdm_customer_id, origen_dato
    FROM mdm_golden_customers g
    WHERE (l.clean_email IS NOT NULL AND l.clean_email = g.email)
       OR (l.clean_email IS NULL AND LENGTH(l.clean_phone) = 10 AND l.clean_phone = g.telefono_10_dig)
    ORDER BY 
        CASE WHEN g.origen_dato = 'ERP + CRM' THEN 1 WHEN g.origen_dato = 'Solo ERP' THEN 2 ELSE 3 END,
        g.mdm_customer_id
    LIMIT 1
) g ON TRUE;


-- ============================================================================
-- FASE 6: AUDITORÍA DE RESULTADOS Y EXPORTACIÓN PARA TABLEAU
-- ============================================================================

-- 6A. Métricas resumen de validación (Ahora calcula sobre los 510 leads exactos)
SELECT origen_dato, metodo_cruce, COUNT(*) AS total
FROM mdm_golden_customers
GROUP BY 1, 2 ORDER BY 1, 2;

SELECT estatus_mdm, COUNT(*) AS total_leads, ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (), 2) AS porcentaje
FROM mdm_leads_enriquecidos
GROUP BY 1 ORDER BY 2 DESC;

-- 6B. Consultas limpias para exportar a CSV (Ejecutar una por una y clic en EXPORT)
SELECT * FROM mdm_golden_customers;
SELECT * FROM mdm_leads_enriquecidos;
SELECT week, source, issue_type, CAST(issue_count AS INTEGER) AS issue_count FROM weekly_issues;