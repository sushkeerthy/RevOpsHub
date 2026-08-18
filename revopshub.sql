-- RevOps AppScript Pipeline — Standalone Query
-- Cardone Ventures | Team Neo | April 2026

WITH

-- ============================================================
-- BASE TABLES
-- ============================================================

tickets AS (
    SELECT
        t.ticket_id,
        t.event_id,
        t.attendee_id,
        t.customer_id,
        t.product_name,
        t.ticket_type,
        t.status,
        t.confirmation_status,
        t.event_date,
        t.ticket_price,
        t.confirmation_method,
        t.confirmed_date,
        t.double_confirm_type,
        t.outreach_restriction,
        t.person_id,
        t.sales_order_id,
        t.purchaser_email,
        t.is_comped
    FROM [dbo].[tenxhub_tickets] t
    WHERE t.product_name LIKE '%Elite Edge%'
      AND LOWER(t.status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
),

attendees AS (
    SELECT
        a.attendee_id,
        a.person_id,
        a.attendee_name,
        a.attendee_email,
        a.attendee_phone,
        a.dietary_restrictions
    FROM [dbo].[tenxhub_attendees] a
),

-- ============================================================
-- ROOM ORIGINATION (session codes → ancillary event names)
-- ============================================================

sessions AS (
    SELECT
        attendee_id,
        STRING_AGG(room_type, ', ') AS room_origination
    FROM (
        SELECT DISTINCT
            at.attendee_id,
            CASE
                WHEN es.SessionName LIKE '%Vertical Summit%'       THEN 'Vertical Summit'
                WHEN es.SessionName LIKE '%Roofing Founders%'      THEN 'Roofing Founders Summit'
                WHEN es.SessionName LIKE '%10X360 Implementation%' THEN '10X360 Implementation'
                ELSE NULL
            END AS room_type
        FROM [dbo].[tenxhub_attendee_ticket_sessions] ats
        JOIN [dbo].[tenxhub_attendee_tickets] at
            ON ats.attendee_ticket_id = at.attendee_ticket_id
        LEFT JOIN [dbo].[Profisee_EventSession] es
            ON ats.event_session_code COLLATE Latin1_General_100_BIN2_UTF8
             = es.EventSessionCode    COLLATE Latin1_General_100_BIN2_UTF8
        WHERE at.attendee_id IN (
            SELECT attendee_id FROM [dbo].[tenxhub_tickets]
            WHERE product_name LIKE '%Elite Edge%'
              AND LOWER(status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
        )
    ) x
    WHERE room_type IS NOT NULL
    GROUP BY attendee_id
),

-- ============================================================
-- CUSTOMERS / COMPANY
-- ============================================================

customers AS (
    SELECT
        c.id              AS customer_id,
        c.name            AS company_name,
        c.cv_customer_id,
        c.abr,
        c.vertical
    FROM [dbo].[tenxhub_customers] c
),

-- dim_customer: HubSpot (business owner contact) first, DWH fallback
-- Chain: DimCustomer → silver_Companies → silver_ContactCompanyAssoc
--        → silver_Contacts WHERE BusinessOwner = 1
dim_customer AS (
    SELECT
        dc.CVCustomerID
            COLLATE Latin1_General_100_BIN2_UTF8                          AS cv_customer_id,
        COALESCE(
            NULLIF(sc.CompanyVertical COLLATE Latin1_General_100_BIN2_UTF8, ''),
            dc.VerticalName
        )                                                                 AS vertical,
        COALESCE(
            NULLIF(sc.AnnualBusinessRevenue COLLATE Latin1_General_100_BIN2_UTF8, ''),
            dc.AnnualBusinessRevenueName
        )                                                                 AS annual_business_revenue
    FROM [dbo].[DimCustomer] dc
    LEFT JOIN [dbo].[Hubspot_Companies] hc
        ON dc.CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8
         = hc.CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8
    LEFT JOIN (
        SELECT
            ca.CompanyID,
            sc.CompanyVertical   COLLATE Latin1_General_100_BIN2_UTF8    AS CompanyVertical,
            sc.AnnualBusinessRevenue COLLATE Latin1_General_100_BIN2_UTF8 AS AnnualBusinessRevenue,
            ROW_NUMBER() OVER (
                PARTITION BY ca.CompanyID
                ORDER BY sc.UpdatedAtUTC DESC
            ) AS rn
        FROM [dbo].[Hubspot_ContactCompanyAssoc] ca
        JOIN [dbo].[Hubspot_Contacts] sc
            ON ca.ContactID = sc.ContactID
        WHERE sc.BusinessOwner = 1
          AND (sc.CompanyVertical IS NOT NULL OR sc.AnnualBusinessRevenue IS NOT NULL)
    ) sc ON hc.CompanyID = sc.CompanyID AND sc.rn = 1
    WHERE dc.CVCustomerID IS NOT NULL
),

-- ============================================================
-- REFUNDS
-- ============================================================

refunds AS (
    SELECT
        tr.sales_order_id,
        'Yes - ' + STRING_AGG(tr.refund_reason, '; ') AS refund_info
    FROM [dbo].[tenxhub_transactions] tr
    WHERE tr.refund_amount > 0
      AND tr.sales_order_id IN (
          SELECT sales_order_id FROM [dbo].[tenxhub_tickets]
          WHERE product_name LIKE '%Elite Edge%'
            AND LOWER(status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
      )
    GROUP BY tr.sales_order_id
),

-- ============================================================
-- NOTES (aggregated per ticket, excluding system notes)
-- ============================================================

ticket_notes AS (
    SELECT
        n.ticket_id,
        STRING_AGG(n.note, CHAR(10)) AS notes
    FROM [dbo].[tenxhub_notes] n
    WHERE n.note NOT LIKE '%Created from POS%'
      AND n.note NOT LIKE '%Created from Fabric%'
      AND n.ticket_id IN (
          SELECT ticket_id FROM [dbo].[tenxhub_tickets]
          WHERE product_name LIKE '%Elite Edge%'
            AND LOWER(status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
      )
    GROUP BY n.ticket_id
),

-- ============================================================
-- NETSUITE (Date of Purchase, 10X360, Sales Rep names)
-- ============================================================

netsuite AS (
    SELECT
        nt.TransactionDisplayName
            COLLATE Latin1_General_100_BIN2_UTF8          AS TransactionDisplayName,
        MIN(nt.TransactionDate)                           AS date_of_purchase,
        MAX(CASE WHEN nt.ClassName = '10X360' THEN 'Yes'
                 ELSE NULL END)                           AS is_10x360,
        MAX(nt.SalesRepName)
            COLLATE Latin1_General_100_BIN2_UTF8          AS SalesRepName,
        MAX(nt.SalesRep2Name)
            COLLATE Latin1_General_100_BIN2_UTF8          AS SalesRep2Name,
        MIN(nt.TransactionID)                             AS TransactionID
    FROM [dbo].[NetSuite_Transaction] nt
    WHERE nt.TransactionType    = 'Sales Order'
      AND nt.TransactionLineID != 0
      AND nt.TransactionDisplayName COLLATE Latin1_General_100_BIN2_UTF8 IN (
          SELECT ('Sales Order #' + sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
          FROM [dbo].[tenxhub_tickets]
          WHERE product_name LIKE '%Elite Edge%'
            AND LOWER(status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
            AND sales_order_id IS NOT NULL
      )
    GROUP BY nt.TransactionDisplayName
),

-- ============================================================
-- NETSUITE NAMES → DimEmployee (Sales Rep name mapping with known mismatches)
-- ============================================================

netsuite_names AS (
    SELECT
        ns.TransactionDisplayName,
        ns.date_of_purchase,
        ns.is_10x360,
        ns.TransactionID,
        CASE ns.SalesRepName
            WHEN 'Michael Leahy'       THEN 'Mike Leahy'
            WHEN 'Matthew Laguerre'    THEN 'Matt Laguerre'
            WHEN 'Nicholas DiPasquale' THEN 'Nick DiPasquale'
            WHEN 'CJ Silas'            THEN 'Carmelo Silas'
            WHEN 'Gabriela O''Brien'   THEN 'Gabriela O''brien'
            WHEN 'Robert Giannini'     THEN 'Rob Giannini'
            WHEN 'William Carpenter'   THEN 'Will Carpenter'
            WHEN 'Matthew Piekutowski' THEN 'Matt Piekutowski'
            WHEN 'Benjamin Turpin'     THEN 'Ben Turpin'
            ELSE ns.SalesRepName
        END AS SalesRepName,
        CASE ns.SalesRep2Name
            WHEN 'Michael Leahy'       THEN 'Mike Leahy'
            WHEN 'Matthew Laguerre'    THEN 'Matt Laguerre'
            WHEN 'Nicholas DiPasquale' THEN 'Nick DiPasquale'
            WHEN 'CJ Silas'            THEN 'Carmelo Silas'
            WHEN 'Gabriela O''Brien'   THEN 'Gabriela O''brien'
            WHEN 'Robert Giannini'     THEN 'Rob Giannini'
            WHEN 'William Carpenter'   THEN 'Will Carpenter'
            WHEN 'Matthew Piekutowski' THEN 'Matt Piekutowski'
            WHEN 'Benjamin Turpin'     THEN 'Ben Turpin'
            ELSE ns.SalesRep2Name
        END AS SalesRep2Name
    FROM netsuite ns
),

dim_employee AS (
    SELECT DISTINCT
        de.EmployeeName COLLATE Latin1_General_100_BIN2_UTF8 AS EmployeeName,
        de.Email        COLLATE Latin1_General_100_BIN2_UTF8 AS Email
    FROM [dbo].[DimEmployee] de
    WHERE de.Email IS NOT NULL
),

-- ============================================================
-- HUBSPOT CONTACT ID (two-path: person_id → CVPersonID, fallback email)
-- ============================================================

hubspot_person AS (
    SELECT
        hc.CVPersonID  COLLATE Latin1_General_100_BIN2_UTF8 AS CVPersonID,
        hc.ContactID
    FROM [dbo].[Hubspot_Contacts] hc
    WHERE hc.CVPersonID IS NOT NULL
),

hubspot_email AS (
    SELECT
        LOWER(hc.Email) COLLATE Latin1_General_100_BIN2_UTF8 AS Email,
        hc.ContactID
    FROM [dbo].[Hubspot_Contacts] hc
    WHERE hc.Email IS NOT NULL
),

-- ============================================================
-- CONFIRMED BY (latest non-system user who updated confirmation status)
-- ============================================================

confirmed_by AS (
    SELECT
        ticket_id,
        changed_by
    FROM (
        SELECT
            h.ticket_id,
            h.changed_by,
            ROW_NUMBER() OVER (PARTITION BY h.ticket_id ORDER BY h.changed_at DESC) AS rn
        FROM [dbo].[tenxhub_history] h
        WHERE h.action = 'Confirmation status updated'
          AND h.changed_by NOT IN ('System', 'bulk-import')
          AND h.ticket_id IN (
              SELECT ticket_id FROM [dbo].[tenxhub_tickets]
              WHERE product_name LIKE '%Elite Edge%'
                AND LOWER(status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
          )
    ) x
    WHERE rn = 1
),

-- ============================================================
-- SOURCE OF PURCHASE + SEAT ATTRIBUTION
-- POS date comparison drives Source of Purchase
-- Source of Purchase drives Seat Attribution
--
-- Source of Purchase logic:
--   POS path: original event = current event → POS, different → Concierge
--   Fallback: history reschedule or human-touched → Concierge, else → POS
--
-- Seat Attribution logic (AppScript rule: POS = always Sales):
--   POS → Sales (always, no exceptions)
--   Concierge + reschedule history + is_comped = 1 → Rescheduled + Comp
--   Concierge + reschedule history + is_comped = 0 → Rescheduled
--   Concierge + no reschedule + is_comped = 1 → Comp
--   Concierge + everything else → Undecided
-- ============================================================

-- Step 1: Get original purchased event date from POS
-- Chain: tenxhub → NetSuite → bronze_OrdersFULL → bronze_OrdersSelectedEventsFULL → silver_Events
pos_original_event AS (
    SELECT
        t.ticket_id,
        pos_evt.StartDate AS original_event_date
    FROM [dbo].[tenxhub_tickets] t
    INNER JOIN (
        SELECT DISTINCT
            TransactionID,
            TransactionDisplayName
        FROM [dbo].[NetSuite_Transaction]
        WHERE TransactionType = 'Sales Order'
          AND TransactionLineID = 0
    ) ns_link
        ON ns_link.TransactionDisplayName = CONCAT('Sales Order #', t.sales_order_id)
            COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [dbo].[POS_OrdersFULL] bof
        ON bof.sales_order_ids COLLATE Latin1_General_100_BIN2_UTF8
         = CAST(ns_link.TransactionID AS VARCHAR(20)) COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [dbo].[POS_OrdersSelectedEventsFULL] bose
        ON bose.order_id = bof.order_id
            COLLATE Latin1_General_100_BIN2_UTF8
        AND bose.selected_event_name LIKE '%Elite Edge%'
    INNER JOIN [dbo].[POS_Events] pos_evt
        ON pos_evt.EventID = bose.selected_event_id
            COLLATE Latin1_General_100_BIN2_UTF8
    WHERE t.product_name LIKE '%Elite Edge%'
      AND LOWER(t.status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
      AND t.sales_order_id IS NOT NULL
),

-- Step 2: Deduplicate POS results (one row per ticket)
pos_original_event_dedup AS (
    SELECT
        ticket_id,
        MIN(original_event_date) AS original_event_date
    FROM pos_original_event
    GROUP BY ticket_id
),

-- Step 3: History — full reschedule (both old+new values, any actor)
history_rescheduled AS (
    SELECT DISTINCT ticket_id
    FROM [dbo].[tenxhub_history]
    WHERE action = 'Event assigned/unassigned'
      AND old_value IS NOT NULL AND old_value != ''
      AND new_value IS NOT NULL AND new_value != ''
),

-- Step 4: History — human-touched Concierge (fallback for no-POS tickets)
-- Excludes system actors: bulk-import, service, System, POS, FabricImport
history_concierge AS (
    SELECT DISTINCT ticket_id
    FROM [dbo].[tenxhub_history]
    WHERE action = 'Event assigned/unassigned'
      AND changed_by NOT IN ('bulk-import', 'service', 'System', 'POS', 'FabricImport')
      AND changed_by IS NOT NULL
),

-- Step 5: Source of Purchase (POS date comparison primary, history fallback)
source_of_purchase AS (
    SELECT
        t.ticket_id,
        CASE
            -- POS path available: compare dates
            WHEN poe.original_event_date IS NOT NULL THEN
                CASE
                    WHEN CAST(t.event_date AS DATE) = poe.original_event_date THEN 'POS'
                    ELSE 'Concierge'
                END
            -- Fallback: no POS match
            WHEN hr.ticket_id IS NOT NULL THEN 'Concierge'
            WHEN hc.ticket_id IS NOT NULL THEN 'Concierge'
            ELSE 'POS'
        END AS source_of_purchase
    FROM [dbo].[tenxhub_tickets] t
    LEFT JOIN pos_original_event_dedup poe ON t.ticket_id = poe.ticket_id
    LEFT JOIN history_rescheduled hr       ON t.ticket_id = hr.ticket_id
    LEFT JOIN history_concierge hc         ON t.ticket_id = hc.ticket_id
    WHERE t.product_name LIKE '%Elite Edge%'
      AND LOWER(t.status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
),

-- Step 6: Seat Attribution (driven by Source of Purchase)
-- POS → Sales (always). Concierge → Rescheduled / Rescheduled + Comp / Undecided / Comp
seat_attribution AS (
    SELECT
        t.ticket_id,
        CASE
            -- POS = always Sales
            WHEN sop.source_of_purchase = 'POS' THEN 'Sales'
            -- Concierge + full reschedule history + comped = Rescheduled + Comp
            WHEN sop.source_of_purchase = 'Concierge' AND hr.ticket_id IS NOT NULL AND t.is_comped = 1 THEN 'Rescheduled + Comp'
            -- Concierge + full reschedule history + not comped = Rescheduled
            WHEN sop.source_of_purchase = 'Concierge' AND hr.ticket_id IS NOT NULL AND t.is_comped = 0 THEN 'Rescheduled'
            -- Concierge + no reschedule + comped = Comp
            WHEN sop.source_of_purchase = 'Concierge' AND t.is_comped = 1 AND hr.ticket_id IS NULL THEN 'Comp'
            -- Concierge + everything else = Undecided
            WHEN sop.source_of_purchase = 'Concierge' THEN 'Undecided'
            -- Safety default
            ELSE 'Sales'
        END AS seat_attribution
    FROM [dbo].[tenxhub_tickets] t
    INNER JOIN source_of_purchase sop ON t.ticket_id = sop.ticket_id
    LEFT JOIN history_rescheduled hr  ON t.ticket_id = hr.ticket_id
    WHERE t.product_name LIKE '%Elite Edge%'
      AND LOWER(t.status) IN ('scheduled', 'attended', 'no show', 'assigned', 'reserved')
)

-- ============================================================
-- FINAL SELECT
-- ============================================================

SELECT
    -- Col 1: Tab Name
    FORMAT(t.event_date, 'MMMM dd') + '-'
        + FORMAT(DATEADD(DAY, 2, t.event_date), 'dd') + ' '
        + FORMAT(t.event_date, 'yyyy')                          AS [Tab Name],

    -- Col 2: Seat Attribution (NEW — Sales, Rescheduled, Rescheduled + Comp, Undecided, Comp)
    sa.seat_attribution                                          AS [Seat Attribution],

    -- Col 3: Product (ticket product name)
    t.product_name                                              AS [Product],

    -- Col 3: Ticket Type
    t.ticket_type                                               AS [Ticket Type],

    -- Col 4: Room Origination
    s.room_origination                                          AS [Room Origination - Addition Effort],

    -- Col 5-7: Attendee Name
    a.attendee_name                                             AS [Attendee Full Name],
    LEFT(a.attendee_name, CHARINDEX(' ', a.attendee_name + ' ') - 1)
                                                                AS [First Name],
    SUBSTRING(a.attendee_name, CHARINDEX(' ', a.attendee_name + ' ') + 1, LEN(a.attendee_name))
                                                                AS [Last Name],

    -- Col 8-10: Contact Info
    a.attendee_email                                            AS [Attendee Email],
    a.attendee_phone                                            AS [Phone Number],
    t.purchaser_email                                           AS [Customer Email],

    -- Col 11: Company
    c.company_name                                              AS [Company Name],

    -- Col 12: Date of Purchase (NetSuite)
    nsr.date_of_purchase                                        AS [Date of Purchase],

    -- Col 13: Original Event Scheduled Date
    t.event_date                                                AS [Original Event Scheduled Date],

    -- Col 14: Attendance Confirmed
    t.confirmation_status                                       AS [Attendance Confirmed],

    -- Col 15: Confirmed By
    cb.changed_by                                               AS [Confirmed By],

    -- Col 16-18: Confirmation Details
    t.double_confirm_type                                       AS [Hotel/Flight Details],
    t.confirmation_method                                       AS [Confirmation Method],
    t.confirmed_date                                            AS [Confirmation Date],

    -- Col 19-21: Manual / Outreach
    NULL                                                        AS [Blast Date],
    t.outreach_restriction                                      AS [Do not contact],
    NULL                                                        AS [Last Called Date],

    -- Col 22-23: Notes & Dietary
    tn.notes                                                    AS [Notes],
    a.dietary_restrictions                                      AS [Dietary Restrictions],

    -- Col 24: Refund
    r.refund_info                                               AS [Refund Request],

    -- Col 25: Price
    t.ticket_price                                              AS [Price],

    -- Col 26-27: Sales Reps (email + name)
    e1.Email                                                    AS [Sales Person 1],
    nsr.SalesRepName                                            AS [Sales Person 1 Name],
    e2.Email                                                    AS [Sales Person 2],
    nsr.SalesRep2Name                                           AS [Sales Person 2 Name],

    -- Col 28: Source of Purchase (POS vs Concierge)
    sop.source_of_purchase                                      AS [Source of Purchase],

    -- Col 29: Comp Type (replaces Is Comped — distinguishes comp with/without sales order)
    CASE
        WHEN t.is_comped = 1 AND t.sales_order_id IS NOT NULL THEN 'Comp - Sales Order'
        WHEN t.is_comped = 1 AND t.sales_order_id IS NULL     THEN 'Comp - No Sales Order'
        ELSE NULL
    END                                                         AS [Comp Type],

    -- Col 31: DATE Selection (DNT)
    t.event_date                                                AS [DATE Selection (DNT)],

    -- Col 32: HubSpot Contact ID
    COALESCE(hp.ContactID, he.ContactID)                        AS [Hubspot Contact ID],

    -- Col 33-34: ABR & Vertical (HubSpot primary via dim_customer, tenxhub fallback)
    COALESCE(dc.annual_business_revenue, c.abr)                 AS [Annual Business Revenue],
    COALESCE(dc.vertical, c.vertical)                           AS [Vertical],

    -- Col 35: Vertical Summit (manual)
    NULL                                                        AS [Vertical Summit?],

    -- Col 36: Status
    t.status                                                    AS [Status],

    -- Col 37-39: Manual columns
    NULL                                                        AS [Products Sold At the Event],
    nsr.is_10x360                                               AS [10X360],
    NULL                                                        AS [TCV]

FROM tickets t

LEFT JOIN attendees a
    ON t.attendee_id = a.attendee_id

LEFT JOIN sessions s
    ON t.attendee_id = s.attendee_id

LEFT JOIN customers c
    ON t.customer_id = c.customer_id

LEFT JOIN dim_customer dc
    ON c.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8
     = dc.cv_customer_id

LEFT JOIN refunds r
    ON t.sales_order_id = r.sales_order_id

LEFT JOIN ticket_notes tn
    ON t.ticket_id = tn.ticket_id

LEFT JOIN netsuite ns
    ON ('Sales Order #' + t.sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
     = ns.TransactionDisplayName

LEFT JOIN netsuite_names nsr
    ON ns.TransactionDisplayName = nsr.TransactionDisplayName

LEFT JOIN dim_employee e1
    ON nsr.SalesRepName COLLATE Latin1_General_100_BIN2_UTF8
     = e1.EmployeeName

LEFT JOIN dim_employee e2
    ON nsr.SalesRep2Name COLLATE Latin1_General_100_BIN2_UTF8
     = e2.EmployeeName

LEFT JOIN hubspot_person hp
    ON a.person_id = hp.CVPersonID

LEFT JOIN hubspot_email he
    ON LOWER(a.attendee_email) COLLATE Latin1_General_100_BIN2_UTF8
     = he.Email

LEFT JOIN confirmed_by cb
    ON t.ticket_id = cb.ticket_id

LEFT JOIN source_of_purchase sop
    ON t.ticket_id = sop.ticket_id

LEFT JOIN seat_attribution sa
    ON t.ticket_id = sa.ticket_id

ORDER BY
    t.event_date,
    c.company_name,
    a.attendee_name;
