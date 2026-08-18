-- ============================================================
-- RevOps AppScript Pipeline — HYBRID v2 (Optimized)
-- Cardone Ventures | Team Neo | August 2026
--
-- Architecture:
--   PART A : SELECT * FROM rpt_revopsattendees  (events < 2026-08-11)
--            → No compute. Reads directly from materialized table.
--   PART B : Live query                          (events >= 2026-08-11)
--            → session_checkins replaced with kiosk_usage + kiosk_registrations
--
-- Optimizations applied (vs v1):
--   [OPT-1] dim_customer_base — DimCustomer read once instead of 4x
--           dim_customer, hubspot_abr, is_10x360, ryb_purchases all reference it
--           DATA SHAPE: unchanged — same rows, same WHERE CVCustomerID IS NOT NULL
--
--   [OPT-2] attendees scoped to active ticket pool (both tickets + no_show_resets)
--           DATA SHAPE: unchanged — still LEFT JOIN; tickets with no attendee still return NULL
--
--   [OPT-3] customers scoped to active ticket pool + COLLATE applied at source
--           DATA SHAPE: unchanged — LEFT JOIN; COLLATE at source = same result as at join time
--
--   [OPT-4] history_rescheduled + history_was_undecided scoped to tickets
--           DATA SHAPE: unchanged — only used by source_of_purchase/seat_attribution (Part B1 only)
--
--   [OPT-5] ticket_transactions scoped to active sales_order_ids (both sources)
--           DATA SHAPE: unchanged — LEFT JOIN; missing sales_order_ids still return NULL date
--
-- Known remaining issues (cannot fix without schema changes):
--   - netsuite CTE: 'Sales Order #' + sales_order_id string concat in JOIN blocks index seek
--   - pos_original_event: CONCAT join through NetSuite → POS, same issue
--
-- SQL Server syntax note:
--   WITH block must appear BEFORE the first SELECT in a UNION ALL.
--   Part A (materialized table) is the first SELECT after the CTE block.
--   CTEs are in scope for all three parts of the UNION ALL.
-- ============================================================

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
        t.travel_details,
        t.outreach_restriction,
        t.person_id,
        t.sales_order_id,
        t.purchaser_email,
        t.is_comped,
        t.undecided_timestamp,
        t.enter_dtm,
        t.is_walkin
    FROM [tenxhub].[ticket-manager].[tickets] t
    WHERE t.event_type_id = 12
      AND (t.event_date >= '2026-08-11' OR t.event_date IS NULL)  -- INCREMENTAL CUTOFF + unscheduled tickets
      AND LOWER(t.status) IN ('scheduled', 'attended', 'no show', 'no_show', 'assigned', 'reserved', 'expired')
),

-- [OPT-2] Scoped to ticket pool from both Part B1 and B2
-- LEFT JOIN in final SELECT means tickets with no attendee still return NULL rows — shape unchanged
attendees AS (
    SELECT
        a.attendee_id,
        a.person_id,
        a.attendee_name,
        a.attendee_email,
        a.attendee_phone,
        a.dietary_restrictions
    FROM [tenxhub].[ticket-manager].[attendees] a
    WHERE a.attendee_id IN (
        SELECT attendee_id FROM tickets             WHERE attendee_id IS NOT NULL
        UNION
        SELECT attendee_id FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
        WHERE event_type_id = 12 AND event_date >= '2026-08-11' AND attendee_id IS NOT NULL
    )
),

-- [OPT-3a] Scoped to ticket pool from both Part B1 and B2
-- [OPT-3b] COLLATE applied at source — removes COLLATE from all downstream JOINs
--          Result is identical: same collation rule, just evaluated once at read time
customers AS (
    SELECT
        c.id                                                     AS customer_id,
        c.name                                                   AS company_name,
        c.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8   AS cv_customer_id,
        c.abr,
        c.vertical,
        c.status                                                 AS customer_status
    FROM [tenxhub].[ticket-manager].[customers] c
    WHERE c.id IN (
        SELECT customer_id FROM tickets             WHERE customer_id IS NOT NULL
        UNION
        SELECT customer_id FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
        WHERE event_type_id = 12 AND event_date >= '2026-08-11' AND customer_id IS NOT NULL
    )
),

-- ============================================================
-- [OPT-1] dim_customer_base — single DimCustomer scan
-- Replaces 4 separate reads of [DWH].[dbo].[DimCustomer]
-- dim_customer, hubspot_abr, is_10x360, ryb_purchases all derive from here
-- ============================================================

dim_customer_base AS (
    SELECT
        dc.CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8    AS cv_customer_id,
        dc.NetSuiteID,
        dc.VerticalName                                          AS vertical,
        dc.AnnualBusinessRevenueName,
        CASE WHEN dc.First10X360PurchaseDate IS NOT NULL
             THEN 'Yes' ELSE NULL END                            AS is_10x360_flag,
        dc.First10X360PurchaseDate                               AS first_10x360_purchase_date
    FROM [DWH].[dbo].[DimCustomer] dc
    WHERE dc.CVCustomerID IS NOT NULL
),

dim_customer AS (
    SELECT cv_customer_id, vertical
    FROM dim_customer_base
),

-- ============================================================
-- ROOM ORIGINATION
-- Uses Profisee silver_EventSession — NOT deprecated
-- ============================================================

sessions AS (
    SELECT
        x.ticket_id,
        STRING_AGG(room_type, ', ') AS room_origination
    FROM (
        SELECT DISTINCT
            att.ticket_id,
            CASE
                WHEN es.SessionName LIKE '%Vertical Summit%'       THEN 'Vertical Summit'
                WHEN es.SessionName LIKE '%Roofing Founders%'      THEN 'Roofing Founders Summit'
                WHEN es.SessionName LIKE '%10X360 Implementation%' THEN '10X360 Implementation'
                ELSE NULL
            END AS room_type
        FROM [tenxhub].[ticket-manager].[attendee_ticket_sessions] ats
        JOIN [tenxhub].[ticket-manager].[attendee_tickets] att
            ON ats.attendee_ticket_id = att.attendee_ticket_id
        LEFT JOIN [Profisee].[dbo].[silver_EventSession] es
            ON ats.event_session_code COLLATE Latin1_General_100_BIN2_UTF8
             = es.CVEventSessionID    COLLATE Latin1_General_100_BIN2_UTF8
        JOIN tickets t
            ON att.ticket_id = t.ticket_id
        WHERE es.Event COLLATE Latin1_General_100_BIN2_UTF8
            = t.event_id COLLATE Latin1_General_100_BIN2_UTF8
    ) x
    WHERE room_type IS NOT NULL
    GROUP BY x.ticket_id
),

-- ============================================================
-- SESSION CHECK-INS — kiosk_usage (replaces a10XEvents, deprecated Aug 2026)
-- ============================================================

session_checkins AS (
    SELECT
        ku.ticket_id COLLATE Latin1_General_100_BIN2_UTF8          AS ticket_id,
        MAX(CASE WHEN kr.session_name LIKE '%General Session Day 1%'
                 THEN 'Yes' ELSE NULL END)                         AS [Registration Day 1],
        MAX(CASE WHEN kr.session_name LIKE '%General Session Day 2%'
                 THEN 'Yes' ELSE NULL END)                         AS [Registration Day 2],
        MAX(CASE WHEN kr.session_name LIKE '%General Session Day 3%'
                 THEN 'Yes' ELSE NULL END)                         AS [Registration Day 3],
        MAX(CASE WHEN kr.session_name LIKE '%Vertical Summit%'
                 THEN 'Yes' ELSE NULL END)                         AS [10X Vertical Summit]
    FROM [tenxhub].[ticket-manager].[kiosk_usage] ku
    JOIN [tenxhub].[ticket-manager].[kiosk_registrations] kr
        ON  ku.session_id = kr.session_id
        AND ku.event_id   = kr.event_id
    WHERE ku.flow_type          = 'badge_printed'
      AND ku.check_in_undone_at IS NULL
      AND ku.ticket_id          IS NOT NULL
    GROUP BY ku.ticket_id
),

-- ============================================================
-- HUBSPOT ABR
-- [OPT-1] References dim_customer_base instead of DimCustomer directly
-- ============================================================

hubspot_abr AS (
    SELECT
        dcb.cv_customer_id,
        COALESCE(
            NULLIF(sc.AnnualBusinessRevenue COLLATE Latin1_General_100_BIN2_UTF8, ''),
            dcb.AnnualBusinessRevenueName
        )                                                          AS annual_business_revenue
    FROM dim_customer_base dcb
    LEFT JOIN (
        SELECT
            CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8 AS CVCustomerID,
            CompanyID,
            ROW_NUMBER() OVER (
                PARTITION BY CVCustomerID
                ORDER BY CompanyID
            ) AS rn
        FROM [Hubspot].[dbo].[silver_Companies]
        WHERE CVCustomerID IS NOT NULL
    ) hc ON dcb.cv_customer_id = hc.CVCustomerID AND hc.rn = 1
    LEFT JOIN (
        SELECT
            ca.CompanyID,
            sc.AnnualBusinessRevenue COLLATE Latin1_General_100_BIN2_UTF8 AS AnnualBusinessRevenue,
            ROW_NUMBER() OVER (
                PARTITION BY ca.CompanyID
                ORDER BY sc.UpdatedAtUTC DESC
            ) AS rn
        FROM [Hubspot].[dbo].[silver_ContactCompanyAssoc] ca
        JOIN [Hubspot].[dbo].[silver_Contacts] sc
            ON ca.ContactID = sc.ContactID
        WHERE sc.BusinessOwner = 1
          AND sc.AnnualBusinessRevenue IS NOT NULL
    ) sc ON hc.CompanyID = sc.CompanyID AND sc.rn = 1
),

-- ============================================================
-- RYB PURCHASES
-- [OPT-1] References dim_customer_base instead of DimCustomer directly
-- ============================================================

ryb_purchases AS (
    SELECT cv_customer_id, ItemName
    FROM (
        SELECT
            dcb.cv_customer_id,
            txn.ItemName COLLATE Latin1_General_100_BIN2_UTF8   AS ItemName,
            ROW_NUMBER() OVER (
                PARTITION BY dcb.cv_customer_id
                ORDER BY txn.TransactionDate DESC
            ) AS rn
        FROM dim_customer_base dcb
        JOIN [NetSuite].[dbo].[silver_Transaction] txn
            ON dcb.NetSuiteID = txn.EntityID
        WHERE txn.ItemName LIKE '%RYB%'
          AND txn.SubsidiaryID = 11
          AND txn.TransactionType IN ('Sales Order', 'Cash Sale')
    ) x
    WHERE rn = 1
),

-- ============================================================
-- 10X360 FLAG + FIRST PURCHASE DATE
-- [OPT-1] References dim_customer_base instead of DimCustomer directly
-- ============================================================

is_10x360 AS (
    SELECT DISTINCT
        cv_customer_id,
        is_10x360_flag,
        first_10x360_purchase_date
    FROM dim_customer_base
),

-- ============================================================
-- REFUNDS
-- Already scoped — unchanged
-- ============================================================

refunds AS (
    SELECT
        tr.sales_order_id,
        'Yes - ' + STRING_AGG(tr.refund_reason, '; ') AS refund_info
    FROM [tenxhub].[ticket-manager].[transactions] tr
    WHERE tr.refund_amount > 0
      AND tr.sales_order_id IN (
          SELECT sales_order_id FROM tickets WHERE sales_order_id IS NOT NULL
          UNION
          SELECT sales_order_id FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
          WHERE event_type_id = 12 AND event_date >= '2026-08-11' AND sales_order_id IS NOT NULL
      )
    GROUP BY tr.sales_order_id
),

-- ============================================================
-- NOTES
-- Already scoped — unchanged
-- ============================================================

ticket_notes AS (
    SELECT
        n.ticket_id,
        STRING_AGG(n.note, ' | ') AS notes
    FROM [tenxhub].[ticket-manager].[notes] n
    WHERE n.note NOT LIKE '%Created from POS%'
      AND n.note NOT LIKE '%Created from Fabric%'
      AND n.ticket_id IN (
          SELECT ticket_id FROM tickets
          UNION
          SELECT ticket_id FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
          WHERE event_type_id = 12 AND event_date >= '2026-08-11'
      )
    GROUP BY n.ticket_id
),

-- ============================================================
-- TICKET TRANSACTIONS — Date of Purchase
-- [OPT-5] Scoped to active sales_order_ids from both sources
-- DATA SHAPE: unchanged — still LEFT JOIN in final SELECT; NULL date if no match
-- ============================================================

ticket_transactions AS (
    SELECT
        tr.sales_order_id,
        MIN(tr.transaction_date) AS date_of_purchase
    FROM [tenxhub].[ticket-manager].[transactions] tr
    WHERE tr.sales_order_id IN (
        SELECT sales_order_id FROM tickets
        WHERE sales_order_id IS NOT NULL
        UNION
        SELECT sales_order_id FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
        WHERE event_type_id = 12 AND event_date >= '2026-08-11' AND sales_order_id IS NOT NULL
    )
    GROUP BY tr.sales_order_id
),

-- ============================================================
-- NETSUITE (Sales Rep names only)
-- NOTE: 'Sales Order #' + sales_order_id concat in JOIN blocks index seek on
--       TransactionDisplayName. Cannot fix without IT adding a parsed column
--       to silver_Transaction. Left as-is intentionally.
-- ============================================================

netsuite AS (
    SELECT
        nt.TransactionDisplayName
            COLLATE Latin1_General_100_BIN2_UTF8          AS TransactionDisplayName,
        MAX(nt.SalesRepName)
            COLLATE Latin1_General_100_BIN2_UTF8          AS SalesRepName,
        MAX(nt.SalesRep2Name)
            COLLATE Latin1_General_100_BIN2_UTF8          AS SalesRep2Name,
        MIN(nt.TransactionID)                             AS TransactionID
    FROM [NetSuite].[dbo].[silver_Transaction] nt
    WHERE nt.TransactionType    = 'Sales Order'
      AND nt.TransactionLineID != 0
      AND nt.TransactionDisplayName COLLATE Latin1_General_100_BIN2_UTF8 IN (
          SELECT ('Sales Order #' + sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
          FROM tickets WHERE sales_order_id IS NOT NULL
          UNION
          SELECT ('Sales Order #' + sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
          FROM [tenxhub].[ticket-manager].[ticket_no_show_resets]
          WHERE event_type_id = 12 AND event_date >= '2026-08-11' AND sales_order_id IS NOT NULL
      )
    GROUP BY nt.TransactionDisplayName
),

-- ============================================================
-- NETSUITE NAMES → DimEmployee
-- ============================================================

netsuite_names AS (
    SELECT
        ns.TransactionDisplayName,
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
    FROM [DWH].[dbo].[DimEmployee] de
    WHERE de.Email IS NOT NULL
),

-- ============================================================
-- HUBSPOT CONTACT ID
-- ============================================================

hubspot_person AS (
    SELECT CVPersonID, ContactID
    FROM (
        SELECT
            hc.CVPersonID  COLLATE Latin1_General_100_BIN2_UTF8 AS CVPersonID,
            hc.ContactID,
            ROW_NUMBER() OVER (
                PARTITION BY hc.CVPersonID
                ORDER BY hc.UpdatedAtUTC DESC
            ) AS rn
        FROM [Hubspot].[dbo].[silver_Contacts] hc
        WHERE hc.CVPersonID IS NOT NULL
    ) x WHERE rn = 1
),

hubspot_email AS (
    SELECT Email, ContactID
    FROM (
        SELECT
            LOWER(hc.Email) COLLATE Latin1_General_100_BIN2_UTF8 AS Email,
            hc.ContactID,
            ROW_NUMBER() OVER (
                PARTITION BY LOWER(hc.Email)
                ORDER BY hc.UpdatedAtUTC DESC
            ) AS rn
        FROM [Hubspot].[dbo].[silver_Contacts] hc
        WHERE hc.Email IS NOT NULL
          AND hc.Email != ''
    ) x WHERE rn = 1
),

-- ============================================================
-- CONFIRMED BY
-- Already scoped to tickets — unchanged
-- ============================================================

confirmed_by AS (
    SELECT ticket_id, changed_by
    FROM (
        SELECT
            h.ticket_id,
            h.changed_by,
            ROW_NUMBER() OVER (PARTITION BY h.ticket_id ORDER BY h.changed_at DESC) AS rn
        FROM [tenxhub].[ticket-manager].[history] h
        WHERE h.action = 'Confirmation status updated'
          AND h.changed_by NOT IN ('System', 'bulk-import')
          AND h.ticket_id IN (SELECT ticket_id FROM tickets)
    ) x
    WHERE rn = 1
),

-- ============================================================
-- SOURCE OF PURCHASE
-- ============================================================

pos_original_event AS (
    SELECT
        t.ticket_id,
        pos_evt.StartDate AS original_event_date
    FROM tickets t
    INNER JOIN (
        SELECT DISTINCT TransactionID, TransactionDisplayName
        FROM [NetSuite].[dbo].[silver_Transaction]
        WHERE TransactionType = 'Sales Order' AND TransactionLineID = 0
    ) ns_link
        ON ns_link.TransactionDisplayName = CONCAT('Sales Order #', t.sales_order_id)
            COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersFULL] bof
        ON bof.sales_order_ids COLLATE Latin1_General_100_BIN2_UTF8
         = CAST(ns_link.TransactionID AS VARCHAR(20)) COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersSelectedEventsFULL] bose
        ON bose.order_id = bof.order_id COLLATE Latin1_General_100_BIN2_UTF8
        AND bose.selected_event_name LIKE '%Elite Edge%'
    INNER JOIN [POS].[dbo].[silver_Events] pos_evt
        ON pos_evt.EventID = bose.selected_event_id COLLATE Latin1_General_100_BIN2_UTF8
    WHERE t.sales_order_id IS NOT NULL

    UNION ALL

    SELECT
        tnsr.ticket_id,
        pos_evt.StartDate AS original_event_date
    FROM [tenxhub].[ticket-manager].[ticket_no_show_resets] tnsr
    INNER JOIN (
        SELECT DISTINCT TransactionID, TransactionDisplayName
        FROM [NetSuite].[dbo].[silver_Transaction]
        WHERE TransactionType = 'Sales Order' AND TransactionLineID = 0
    ) ns_link
        ON ns_link.TransactionDisplayName = CONCAT('Sales Order #', tnsr.sales_order_id)
            COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersFULL] bof
        ON bof.sales_order_ids COLLATE Latin1_General_100_BIN2_UTF8
         = CAST(ns_link.TransactionID AS VARCHAR(20)) COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersSelectedEventsFULL] bose
        ON bose.order_id = bof.order_id COLLATE Latin1_General_100_BIN2_UTF8
        AND bose.selected_event_name LIKE '%Elite Edge%'
    INNER JOIN [POS].[dbo].[silver_Events] pos_evt
        ON pos_evt.EventID = bose.selected_event_id COLLATE Latin1_General_100_BIN2_UTF8
    WHERE tnsr.sales_order_id IS NOT NULL
      AND tnsr.event_type_id = 12
      AND tnsr.event_date >= '2026-08-11'
),

pos_original_event_dedup AS (
    SELECT ticket_id, MIN(original_event_date) AS original_event_date
    FROM pos_original_event
    GROUP BY ticket_id
),

-- ============================================================
-- HISTORY CTEs
-- [OPT-4] Scoped to tickets — full table scan eliminated
-- DATA SHAPE: unchanged — only consumed by source_of_purchase + seat_attribution
--             which are only in Part B1 (active tickets). No Part B2 dependency.
-- ============================================================

history_rescheduled AS (
    SELECT DISTINCT ticket_id
    FROM [tenxhub].[ticket-manager].[history]
    WHERE action = 'Event assigned/unassigned'
      AND old_value IS NOT NULL AND old_value != ''
      AND new_value IS NOT NULL AND new_value != ''
      AND ticket_id IN (SELECT ticket_id FROM tickets)   -- [OPT-4]
),

history_was_undecided AS (
    SELECT DISTINCT ticket_id
    FROM [tenxhub].[ticket-manager].[history]
    WHERE action = 'Status changed to undecided'
      AND ticket_id IN (SELECT ticket_id FROM tickets)   -- [OPT-4]
),

source_of_purchase AS (
    SELECT
        t.ticket_id,
        CASE
            WHEN poe.original_event_date IS NOT NULL THEN
                CASE
                    WHEN CAST(t.event_date AS DATE) = poe.original_event_date THEN 'POS'
                    ELSE 'Concierge'
                END
            WHEN hwu.ticket_id IS NOT NULL THEN 'Concierge'
            WHEN t.undecided_timestamp IS NOT NULL THEN 'Concierge'
            WHEN hr.ticket_id IS NOT NULL THEN 'Concierge'
            ELSE 'POS'
        END AS source_of_purchase
    FROM tickets t
    LEFT JOIN pos_original_event_dedup poe ON t.ticket_id = poe.ticket_id
    LEFT JOIN history_rescheduled hr       ON t.ticket_id = hr.ticket_id
    LEFT JOIN history_was_undecided hwu    ON t.ticket_id = hwu.ticket_id
),

seat_attribution AS (
    SELECT
        t.ticket_id,
        CASE
            WHEN COALESCE(t.is_comped, 0) = 1 AND (t.sales_order_id IS NULL OR t.sales_order_id = '') AND hr.ticket_id IS NOT NULL THEN 'Rescheduled + Comp'
            WHEN COALESCE(t.is_comped, 0) = 1 AND (t.sales_order_id IS NULL OR t.sales_order_id = '') THEN 'Comp'
            WHEN hr.ticket_id IS NOT NULL AND (hwu.ticket_id IS NOT NULL OR t.undecided_timestamp IS NOT NULL) THEN 'Rescheduled + Undecided'
            WHEN hr.ticket_id IS NOT NULL THEN 'Rescheduled'
            WHEN sop.source_of_purchase = 'POS' THEN 'Sales'
            WHEN sop.source_of_purchase = 'Concierge' THEN 'Undecided'
            ELSE 'Sales'
        END AS seat_attribution
    FROM tickets t
    INNER JOIN source_of_purchase sop  ON t.ticket_id = sop.ticket_id
    LEFT JOIN history_rescheduled hr   ON t.ticket_id = hr.ticket_id
    LEFT JOIN history_was_undecided hwu ON t.ticket_id = hwu.ticket_id
)


-- ============================================================
-- PART A — HISTORICAL (pre Aug 11 2026)
-- No computation — reads directly from materialized table
-- CTEs above are defined but not used here; they serve Parts B1 and B2
-- ============================================================

SELECT *
FROM [a10XEvents].[dbo].[rpt_revopsattendees]
WHERE DATESelectionDNT < '2026-08-11'


UNION ALL


-- ============================================================
-- PART B1 — LIVE: Active Pipeline Tickets (>= Aug 11 2026)
-- [OPT-3b] COLLATE removed from cv_customer_id JOINs — already normalized in customers CTE
-- ============================================================

SELECT
    'Active'                                                    AS [Record Type],
    FORMAT(t.event_date, 'MMMM dd') + '-'
        + FORMAT(DATEADD(DAY, 2, t.event_date), 'dd') + ' '
        + FORMAT(t.event_date, 'yyyy')                          AS [Tab Name],
    sa.seat_attribution                                         AS [Seat Attribution],
    t.product_name                                              AS [Product],
    t.ticket_type                                               AS [Ticket Type],
    s.room_origination                                          AS [Room Origination - Addition Effort],
    a.attendee_name                                             AS [Attendee Full Name],
    LEFT(a.attendee_name, CHARINDEX(' ', a.attendee_name + ' ') - 1)
                                                                AS [First Name],
    SUBSTRING(a.attendee_name, CHARINDEX(' ', a.attendee_name + ' ') + 1, LEN(a.attendee_name))
                                                                AS [Last Name],
    a.attendee_email                                            AS [Attendee Email],
    a.attendee_phone                                            AS [Phone Number],
    t.purchaser_email                                           AS [Customer Email],
    c.company_name                                              AS [Company Name],
    tt.date_of_purchase                                         AS [Date of Purchase],
    poe.original_event_date                                     AS [Original Event Scheduled Date],
    t.confirmation_status                                       AS [Attendance Confirmed],
    cb.changed_by                                               AS [Confirmed By],
    t.travel_details                                            AS [Hotel/Flight Details],
    t.confirmation_method                                       AS [Confirmation Method],
    t.confirmed_date                                            AS [Confirmation Date],
    NULL                                                        AS [Blast Date],
    t.outreach_restriction                                      AS [Do not contact],
    NULL                                                        AS [Last Called Date],
    tn.notes                                                    AS [Notes],
    a.dietary_restrictions                                      AS [Dietary Restrictions],
    r.refund_info                                               AS [Refund Request],
    t.ticket_price                                              AS [Price],
    e1.Email                                                    AS [Sales Person 1],
    nsr.SalesRepName                                            AS [Sales Person 1 Name],
    e2.Email                                                    AS [Sales Person 2],
    nsr.SalesRep2Name                                           AS [Sales Person 2 Name],
    sop.source_of_purchase                                      AS [Source of Purchase],
    CASE
        WHEN COALESCE(t.is_comped, 0) = 1 AND t.sales_order_id IS NOT NULL THEN 'Comp - Sales Order'
        WHEN COALESCE(t.is_comped, 0) = 1 AND t.sales_order_id IS NULL     THEN 'Comp - No Sales Order'
        ELSE NULL
    END                                                         AS [Comp Type],
    t.event_date                                                AS [DATE Selection (DNT)],
    COALESCE(hp.ContactID, he.ContactID)                        AS [Hubspot Contact ID],
    CASE COALESCE(habr.annual_business_revenue, c.abr)
        WHEN '1 Million+'          THEN '$1 Million+'
        WHEN '2 Million +'         THEN '$2 Million+'
        WHEN '2 Million+'          THEN '$2 Million+'
        WHEN '3 Million+'          THEN '$3 Million+'
        WHEN '4 Million+'          THEN '$4 Million+'
        WHEN '5 Million+'          THEN '$5 Million+'
        WHEN '6 Million+'          THEN '$6 Million+'
        WHEN '7 Million+'          THEN '$7 Million+'
        WHEN '8 Million+'          THEN '$8 Million+'
        WHEN '9 Million+'          THEN '$9 Million+'
        WHEN '10 Million+'         THEN '$10 Million+'
        WHEN '20 Million+'         THEN '$20 Million+'
        WHEN '30 Million+'         THEN '$30 Million+'
        WHEN '50 Million+'         THEN '$50 Million+'
        WHEN '100 Million+'        THEN '$100 Million+'
        WHEN 'Under $100k'         THEN 'Under $100k'
        WHEN 'No Business Revenue' THEN 'No Business Revenue'
        WHEN 'To Be Determined'    THEN NULL
        WHEN '8'                   THEN NULL
        ELSE COALESCE(habr.annual_business_revenue, c.abr)
    END                                                         AS [Annual Business Revenue],
    COALESCE(dc.vertical,
        CASE c.vertical COLLATE Latin1_General_100_BIN2_UTF8
            WHEN '1'  THEN 'To Be Determined'
            WHEN '3'  THEN 'Automotive'
            WHEN '4'  THEN 'Community Services'
            WHEN '5'  THEN 'Construction'
            WHEN '6'  THEN 'Education'
            WHEN '7'  THEN 'Extractive Industries'
            WHEN '8'  THEN 'Farm & Ranch'
            WHEN '9'  THEN 'Health Care'
            WHEN '10' THEN 'Home Services'
            WHEN '11' THEN 'HVAC, Plumbing & Electrical'
            WHEN '12' THEN 'Information Technology'
            WHEN '13' THEN 'Insurance'
            WHEN '14' THEN 'Leasing and Renting'
            WHEN '15' THEN 'Manufacturing'
            WHEN '16' THEN 'Professional Services'
            WHEN '17' THEN 'Real Estate'
            WHEN '18' THEN 'Repair and Maintenance'
            WHEN '19' THEN 'Retail'
            WHEN '20' THEN 'Roofing'
            WHEN '21' THEN 'Warehouse and Storage'
            WHEN '22' THEN 'Wholesale'
            ELSE c.vertical
        END
    )                                                           AS [Vertical],
    CASE c.customer_status
        WHEN '3' THEN 'E125'
        WHEN '4' THEN 'E250'
        ELSE NULL
    END                                                         AS [Elite Status],
    NULL                                                        AS [Vertical Summit?],
    t.status                                                    AS [Status],
    NULL                                                        AS [Products Sold At the Event],
    x360.is_10x360_flag                                         AS [10X360],
    x360.first_10x360_purchase_date                             AS [First 10X360 Purchase Date],
    ryb.ItemName                                                AS [RYB],
    NULL                                                        AS [TCV],
    c.cv_customer_id                                            AS [CV-CustomerID],
    a.person_id                                                 AS [CVPersonID],
    CASE WHEN LOWER(t.status) = 'attended' THEN 'Yes'
         ELSE 'No'
    END                                                         AS [Attended],
    'No'                                                        AS [Is No Show],
    CASE WHEN t.is_walkin = 1 THEN 'Yes' ELSE 'No' END         AS [Walk-In],
    sc.[Registration Day 1],
    sc.[Registration Day 2],
    sc.[Registration Day 3],
    sc.[10X Vertical Summit],
    t.ticket_id                                                 AS [Ticket ID]

FROM tickets t
LEFT JOIN attendees a              ON t.attendee_id = a.attendee_id
LEFT JOIN sessions s               ON t.ticket_id = s.ticket_id
LEFT JOIN customers c              ON t.customer_id = c.customer_id
LEFT JOIN dim_customer dc          ON c.cv_customer_id = dc.cv_customer_id          -- COLLATE dropped: normalized in customers CTE
LEFT JOIN hubspot_abr habr         ON c.cv_customer_id = habr.cv_customer_id        -- COLLATE dropped
LEFT JOIN ryb_purchases ryb        ON c.cv_customer_id = ryb.cv_customer_id         -- COLLATE dropped
LEFT JOIN is_10x360 x360           ON c.cv_customer_id = x360.cv_customer_id        -- COLLATE dropped
LEFT JOIN refunds r                ON t.sales_order_id = r.sales_order_id
LEFT JOIN ticket_notes tn          ON t.ticket_id = tn.ticket_id
LEFT JOIN ticket_transactions tt   ON t.sales_order_id = tt.sales_order_id
LEFT JOIN netsuite ns              ON ('Sales Order #' + t.sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8 = ns.TransactionDisplayName
LEFT JOIN netsuite_names nsr       ON ns.TransactionDisplayName = nsr.TransactionDisplayName
LEFT JOIN dim_employee e1          ON nsr.SalesRepName  COLLATE Latin1_General_100_BIN2_UTF8 = e1.EmployeeName
LEFT JOIN dim_employee e2          ON nsr.SalesRep2Name COLLATE Latin1_General_100_BIN2_UTF8 = e2.EmployeeName
LEFT JOIN hubspot_person hp        ON a.person_id = hp.CVPersonID
LEFT JOIN hubspot_email he         ON LOWER(a.attendee_email) COLLATE Latin1_General_100_BIN2_UTF8 = he.Email
LEFT JOIN confirmed_by cb          ON t.ticket_id = cb.ticket_id
LEFT JOIN source_of_purchase sop   ON t.ticket_id = sop.ticket_id
LEFT JOIN pos_original_event_dedup poe ON t.ticket_id = poe.ticket_id
LEFT JOIN seat_attribution sa      ON t.ticket_id = sa.ticket_id
LEFT JOIN session_checkins sc      ON t.ticket_id COLLATE Latin1_General_100_BIN2_UTF8 = sc.ticket_id


UNION ALL


-- ============================================================
-- PART B2 — LIVE: No-Show Reset Records (>= Aug 11 2026)
-- Session check-in columns NULL by design (did not attend)
-- Note: tnsr.cv_customer_id comes from ticket_no_show_resets directly
--       (not through customers CTE) so COLLATE still needed on those joins
-- ============================================================

SELECT
    'No Show Reset'                                             AS [Record Type],
    FORMAT(tnsr.event_date, 'MMMM dd') + '-'
        + FORMAT(DATEADD(DAY, 2, tnsr.event_date), 'dd') + ' '
        + FORMAT(tnsr.event_date, 'yyyy')                       AS [Tab Name],
    NULL                                                        AS [Seat Attribution],
    tnsr.product_name                                           AS [Product],
    tnsr.ticket_type                                            AS [Ticket Type],
    NULL                                                        AS [Room Origination - Addition Effort],
    tnsr.attendee_name                                          AS [Attendee Full Name],
    LEFT(tnsr.attendee_name, CHARINDEX(' ', tnsr.attendee_name + ' ') - 1)
                                                                AS [First Name],
    SUBSTRING(tnsr.attendee_name, CHARINDEX(' ', tnsr.attendee_name + ' ') + 1, LEN(tnsr.attendee_name))
                                                                AS [Last Name],
    tnsr.attendee_email                                         AS [Attendee Email],
    tnsr.attendee_phone                                         AS [Phone Number],
    tnsr.purchaser_email                                        AS [Customer Email],
    tnsr.customer_name                                          AS [Company Name],
    tt2.date_of_purchase                                        AS [Date of Purchase],
    poe2.original_event_date                                    AS [Original Event Scheduled Date],
    tnsr.confirmation_status                                    AS [Attendance Confirmed],
    tnsr.confirmed_by                                           AS [Confirmed By],
    tnsr.travel_details                                         AS [Hotel/Flight Details],
    tnsr.confirmation_method                                    AS [Confirmation Method],
    tnsr.confirmed_date                                         AS [Confirmation Date],
    NULL                                                        AS [Blast Date],
    tnsr.outreach_restriction                                   AS [Do not contact],
    NULL                                                        AS [Last Called Date],
    tn2.notes                                                   AS [Notes],
    a2.dietary_restrictions                                     AS [Dietary Restrictions],
    r2.refund_info                                              AS [Refund Request],
    tnsr.ticket_price                                           AS [Price],
    e3.Email                                                    AS [Sales Person 1],
    nsr2.SalesRepName                                           AS [Sales Person 1 Name],
    e4.Email                                                    AS [Sales Person 2],
    nsr2.SalesRep2Name                                          AS [Sales Person 2 Name],
    NULL                                                        AS [Source of Purchase],
    CASE
        WHEN COALESCE(tnsr.is_comped, 0) = 1 AND tnsr.sales_order_id IS NOT NULL THEN 'Comp - Sales Order'
        WHEN COALESCE(tnsr.is_comped, 0) = 1 AND tnsr.sales_order_id IS NULL     THEN 'Comp - No Sales Order'
        ELSE NULL
    END                                                         AS [Comp Type],
    tnsr.event_date                                             AS [DATE Selection (DNT)],
    he2.ContactID                                               AS [Hubspot Contact ID],
    CASE COALESCE(habr2.annual_business_revenue, c2.abr)
        WHEN '1 Million+'          THEN '$1 Million+'
        WHEN '2 Million +'         THEN '$2 Million+'
        WHEN '2 Million+'          THEN '$2 Million+'
        WHEN '3 Million+'          THEN '$3 Million+'
        WHEN '4 Million+'          THEN '$4 Million+'
        WHEN '5 Million+'          THEN '$5 Million+'
        WHEN '6 Million+'          THEN '$6 Million+'
        WHEN '7 Million+'          THEN '$7 Million+'
        WHEN '8 Million+'          THEN '$8 Million+'
        WHEN '9 Million+'          THEN '$9 Million+'
        WHEN '10 Million+'         THEN '$10 Million+'
        WHEN '20 Million+'         THEN '$20 Million+'
        WHEN '30 Million+'         THEN '$30 Million+'
        WHEN '50 Million+'         THEN '$50 Million+'
        WHEN '100 Million+'        THEN '$100 Million+'
        WHEN 'Under $100k'         THEN 'Under $100k'
        WHEN 'No Business Revenue' THEN 'No Business Revenue'
        WHEN 'To Be Determined'    THEN NULL
        WHEN '8'                   THEN NULL
        ELSE COALESCE(habr2.annual_business_revenue, c2.abr)
    END                                                         AS [Annual Business Revenue],
    COALESCE(dc2.vertical,
        CASE tnsr.vertical COLLATE Latin1_General_100_BIN2_UTF8
            WHEN '1'  THEN 'To Be Determined'
            WHEN '3'  THEN 'Automotive'
            WHEN '4'  THEN 'Community Services'
            WHEN '5'  THEN 'Construction'
            WHEN '6'  THEN 'Education'
            WHEN '7'  THEN 'Extractive Industries'
            WHEN '8'  THEN 'Farm & Ranch'
            WHEN '9'  THEN 'Health Care'
            WHEN '10' THEN 'Home Services'
            WHEN '11' THEN 'HVAC, Plumbing & Electrical'
            WHEN '12' THEN 'Information Technology'
            WHEN '13' THEN 'Insurance'
            WHEN '14' THEN 'Leasing and Renting'
            WHEN '15' THEN 'Manufacturing'
            WHEN '16' THEN 'Professional Services'
            WHEN '17' THEN 'Real Estate'
            WHEN '18' THEN 'Repair and Maintenance'
            WHEN '19' THEN 'Retail'
            WHEN '20' THEN 'Roofing'
            WHEN '21' THEN 'Warehouse and Storage'
            WHEN '22' THEN 'Wholesale'
            ELSE tnsr.vertical
        END
    )                                                           AS [Vertical],
    tnsr.customer_elite_status                                  AS [Elite Status],
    NULL                                                        AS [Vertical Summit?],
    tnsr.source_ticket_status                                   AS [Status],
    NULL                                                        AS [Products Sold At the Event],
    x360_2.is_10x360_flag                                       AS [10X360],
    x360_2.first_10x360_purchase_date                           AS [First 10X360 Purchase Date],
    ryb2.ItemName                                               AS [RYB],
    NULL                                                        AS [TCV],
    tnsr.cv_customer_id                                         AS [CV-CustomerID],
    NULL                                                        AS [CVPersonID],
    'No'                                                        AS [Attended],
    'Yes'                                                       AS [Is No Show],
    'No'                                                        AS [Walk-In],
    NULL                                                        AS [Registration Day 1],
    NULL                                                        AS [Registration Day 2],
    NULL                                                        AS [Registration Day 3],
    NULL                                                        AS [10X Vertical Summit],
    tnsr.ticket_id                                              AS [Ticket ID]

FROM [tenxhub].[ticket-manager].[ticket_no_show_resets] tnsr
LEFT JOIN attendees a2             ON tnsr.attendee_id = a2.attendee_id
LEFT JOIN customers c2             ON tnsr.customer_id = c2.customer_id
LEFT JOIN dim_customer dc2         ON tnsr.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8 = dc2.cv_customer_id
LEFT JOIN hubspot_abr habr2        ON tnsr.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8 = habr2.cv_customer_id
LEFT JOIN ryb_purchases ryb2       ON tnsr.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8 = ryb2.cv_customer_id
LEFT JOIN is_10x360 x360_2         ON tnsr.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8 = x360_2.cv_customer_id
LEFT JOIN refunds r2               ON tnsr.sales_order_id = r2.sales_order_id
LEFT JOIN ticket_notes tn2         ON tnsr.ticket_id = tn2.ticket_id
LEFT JOIN ticket_transactions tt2  ON tnsr.sales_order_id = tt2.sales_order_id
LEFT JOIN netsuite ns2             ON ('Sales Order #' + tnsr.sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8 = ns2.TransactionDisplayName
LEFT JOIN netsuite_names nsr2      ON ns2.TransactionDisplayName = nsr2.TransactionDisplayName
LEFT JOIN dim_employee e3          ON nsr2.SalesRepName  COLLATE Latin1_General_100_BIN2_UTF8 = e3.EmployeeName
LEFT JOIN dim_employee e4          ON nsr2.SalesRep2Name COLLATE Latin1_General_100_BIN2_UTF8 = e4.EmployeeName
LEFT JOIN hubspot_email he2        ON LOWER(tnsr.attendee_email) COLLATE Latin1_General_100_BIN2_UTF8 = he2.Email
LEFT JOIN pos_original_event_dedup poe2 ON tnsr.ticket_id = poe2.ticket_id

WHERE tnsr.event_type_id = 12
  AND tnsr.event_date >= '2026-08-11'            -- INCREMENTAL CUTOFF


ORDER BY
    DATESelectionDNT,
    CompanyName,
    AttendeeFullName;