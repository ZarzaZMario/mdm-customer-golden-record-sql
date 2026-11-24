# Customer Golden Record with SQL (MDM)

I built this project to practice Master Data Management (MDM) in PostgreSQL: profile messy customer extracts, standardize and deduplicate them, and unify them into a single golden customer record that marketing leads can be matched against.

## Business problem

Customer data arrives from three operational systems that do not share a common identifier:

- **ERP** — billing customers (`customer_no`, legal name, RFC, credit limit)
- **CRM** — contacts (`contact_id`, first/last name, company)
- **Marketing** — inbound leads (`lead_id`, signup channel)

The same person can appear in more than one system, or more than once in the same system, with different IDs, phone formats, and incomplete fields. The goal is to produce one trusted customer record (the golden record) and to flag which marketing leads are already customers versus net-new prospects.

## Data sources

All person and company records are **synthetic**. They are fictitious extracts designed to look like raw Mexican-market data (mixed accents, phone formats, dates, and catalogs). They do not represent real people or real accounts.

| Table | Rows | Description |
|---|---:|---|
| `erp_customers` | 750 | Raw ERP customer extract |
| `crm_customers` | 940 | Raw CRM contact extract |
| `marketing_leads` | 510 | Raw marketing lead extract |
| `weekly_issues` | 269 | Weekly data-quality issue log by source |

Raw files live in `data/` (CSV). `data/seed_postgres.sql` creates the four staging tables and loads the same rows.

I did not clean the source files before loading them. All standardization happens in SQL views.

The raw `marketing_leads` extract has 510 rows but only 505 distinct `lead_id` values: five IDs appear twice in the source file.

## Approach

The script in `sql/mdm_customer_golden_record.sql` is organized in six phases:

1. **Schema exploration** — inspect column types and sample raw rows from each table.
2. **Data profiling** — row counts, unique/missing IDs and emails, and state-catalog variations.
3. **Integrity, duplicates, and disguised nulls** — confirm that ERP and CRM IDs do not overlap, list repeated emails, and count records without a valid email that can still be recovered by phone or RFC.
4. **Staging** — create cleaned, deduplicated views (`stg_crm_customers`, `stg_erp_customers`) without changing the raw tables.
5. **Golden record and lead enrichment** — unify ERP and CRM into `mdm_golden_customers`, then match marketing leads in `mdm_leads_enriquecidos`.
6. **Audit and export** — summarize the golden record and lead status, and select the clean result sets for CSV export to Tableau.

## Matching and survivorship rules

These are the rules implemented in the script:

- **Email:** trim and lowercase. Values such as `n/a`, `na`, `null`, `-`, `none`, `sin correo`, or any value without `@`, are treated as missing.
- **Phone:** keep digits only and take the last 10 digits.
- **Match key:** use the cleaned email when it exists; otherwise `TEL_` plus the 10-digit phone. Rows with no usable email or phone are not included in staging.
- **CRM deduplication:** one row per match key, keeping the latest `updated_at` (then `contact_id`).
- **ERP deduplication:** one row per match key, keeping the latest `last_invoice_date` (then RFC, then `customer_no`).
- **Golden record:** full outer join of the two staging views on the match key. A record can be `ERP + CRM`, `Solo ERP`, or `Solo CRM`. The join method is `Email` or `Teléfono (Rescatado)` when the key starts with `TEL_`.
- **Field survivorship:** contact name prefers CRM, then ERP; company / legal name prefers ERP `razon_social`, then CRM company; phone prefers CRM, then ERP; address, city, state, and postal code prefer CRM, then ERP; RFC, credit limit, currency, and account status come from ERP (with defaults `MXN` and `Prospecto CRM` when ERP is absent).
- **Leads:** the same email and phone cleaning is applied. Each lead is matched to at most one golden record with a `LEFT JOIN LATERAL … LIMIT 1`, on email, or on the 10-digit phone when the lead has no email. If several golden records share that phone, the match prefers `ERP + CRM`, then `Solo ERP`, then `Solo CRM`. The status is either `Ya es Cliente (…)` with the golden-record source, or `Prospecto Nuevo (No en ERP/CRM)`.

## Data quality notes

A few checks in the script keep the audit and the match counts aligned with the raw extracts:

- The internal-duplicate email query excludes sentinel values such as `n/a`, `na`, `null`, and `-`.
- Credit limits that use a comma as the decimal separator (for example `15000,00`) are normalized before conversion, so those amounts are not inflated. The maximum cleaned credit limit in this dataset is 500,000.
- The lateral `LIMIT 1` join above keeps the enrichment view at one golden match per lead row, even when a phone number appears on more than one customer.
- Phase 6 status percentages are calculated over the 510 lead rows.

## Key results

Audit queries in Phase 6 returned the following totals on this dataset.

**Golden record (`mdm_golden_customers`): 1,172 rows**

| Source (`origen_dato`) | Match method (`metodo_cruce`) | Rows |
|---|---|---:|
| ERP + CRM | Email | 325 |
| ERP + CRM | Teléfono (Rescatado) | 5 |
| Solo CRM | Email | 423 |
| Solo CRM | Teléfono (Rescatado) | 64 |
| Solo ERP | Email | 277 |
| Solo ERP | Teléfono (Rescatado) | 78 |

**Lead enrichment (`mdm_leads_enriquecidos`): 510 rows**

Of those, 333 leads (65.29%) already match a golden-record customer and 177 (34.71%) are net-new prospects.

| Status (`estatus_mdm`) | Rows | Share |
|---|---:|---:|
| Prospecto Nuevo (No en ERP/CRM) | 177 | 34.71% |
| Ya es Cliente (Solo CRM) | 177 | 34.71% |
| Ya es Cliente (Solo ERP) | 82 | 16.08% |
| Ya es Cliente (ERP + CRM) | 74 | 14.51% |

The enrichment view keeps one row per source row, so the five duplicated `lead_id` values from the raw extract still appear twice.

## How to run

You need PostgreSQL (this project was run on PostgreSQL 17).

```bash
createdb mdm_practice
psql -d mdm_practice -f data/seed_postgres.sql
psql -d mdm_practice -f sql/mdm_customer_golden_record.sql
```

Or, in pgAdmin: create an empty database, run `data/seed_postgres.sql`, then run `sql/mdm_customer_golden_record.sql`.

The last statements in Phase 6 (`SELECT * FROM mdm_golden_customers`, `SELECT * FROM mdm_leads_enriquecidos`, and the weekly issues extract) are the queries I export to CSV for Tableau.

## Tools

- PostgreSQL (SQL views, CTEs, window functions, and regular expressions)
- Tableau (for the exported CSVs)

## Future work

- Build a Tableau dashboard on the golden record, lead status, and weekly quality issues
- Add fuzzy matching on names for records that do not share a clean email or phone
- Extend catalog standardization (states, currencies, account status) and survivorship rules
