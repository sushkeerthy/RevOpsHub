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
        t.is_comped,
        t.undecided_timestamp
    FROM [tenxhub].[ticket-manager].[tickets] t
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
    FROM [tenxhub].[ticket-manager].[attendees] a
),

-- ============================================================
-- ROOM ORIGINATION (session codes → ancillary event names)
-- Scoped to current event: joins silver_EventSession.Event to tickets.event_id
-- Uses ticket_id (not attendee_id) to avoid cross-ticket session leakage
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
-- CUSTOMERS / COMPANY
-- ============================================================

customers AS (
    SELECT
        c.id              AS customer_id,
        c.name            AS company_name,
        c.cv_customer_id,
        c.abr,
        c.vertical,
        c.status          AS customer_status
    FROM [tenxhub].[ticket-manager].[customers] c
),

-- dim_customer: Vertical from DWH (clean names RevOps expects)
dim_customer AS (
    SELECT
        dc.CVCustomerID
            COLLATE Latin1_General_100_BIN2_UTF8  AS cv_customer_id,
        dc.VerticalName                           AS vertical
    FROM [DWH].[dbo].[DimCustomer] dc
    WHERE dc.CVCustomerID IS NOT NULL
),

-- hubspot_abr: ABR from HubSpot contact level (business owner)
-- Per Yash: use contact-level ABR, not company-level, because entrepreneurs
-- with multiple companies may transact under a company that doesn't reflect their true size
-- Chain: DimCustomer → silver_Companies → silver_ContactCompanyAssoc
--        → silver_Contacts WHERE BusinessOwner = 1
-- Falls back to DWH AnnualBusinessRevenueName if HubSpot has no data
hubspot_abr AS (
    SELECT
        dc.CVCustomerID
            COLLATE Latin1_General_100_BIN2_UTF8                          AS cv_customer_id,
        COALESCE(
            NULLIF(sc.AnnualBusinessRevenue COLLATE Latin1_General_100_BIN2_UTF8, ''),
            dc.AnnualBusinessRevenueName
        )                                                                 AS annual_business_revenue
    FROM [DWH].[dbo].[DimCustomer] dc
    LEFT JOIN [Hubspot].[dbo].[silver_Companies] hc
        ON dc.CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8
         = hc.CVCustomerID COLLATE Latin1_General_100_BIN2_UTF8
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
    WHERE dc.CVCustomerID IS NOT NULL
),

-- ============================================================
-- RYB PURCHASES (via DimCustomer → NetSuite)
-- Chain: customers.cv_customer_id → DimCustomer.CVCustomerID → NetSuiteID
--        → silver_Transaction.EntityID WHERE ItemName LIKE '%RYB%'
-- ============================================================

ryb_purchases AS (
    SELECT
        cv_customer_id,
        ItemName
    FROM (
        SELECT
            dc.CVCustomerID
                COLLATE Latin1_General_100_BIN2_UTF8    AS cv_customer_id,
            txn.ItemName
                COLLATE Latin1_General_100_BIN2_UTF8    AS ItemName,
            ROW_NUMBER() OVER (
                PARTITION BY dc.CVCustomerID
                ORDER BY txn.TransactionDate DESC
            ) AS rn
        FROM [DWH].[dbo].[DimCustomer] dc
        JOIN [NetSuite].[dbo].[silver_Transaction] txn
            ON dc.NetSuiteID = txn.EntityID
        WHERE txn.ItemName LIKE '%RYB%'
          AND txn.SubsidiaryID = 11
          AND txn.TransactionType IN ('Sales Order', 'Cash Sale')
          AND dc.CVCustomerID IS NOT NULL
    ) x
    WHERE rn = 1
),

-- ============================================================
-- REFUNDS
-- ============================================================

refunds AS (
    SELECT
        tr.sales_order_id,
        'Yes - ' + STRING_AGG(tr.refund_reason, '; ') AS refund_info
    FROM [tenxhub].[ticket-manager].[transactions] tr
    WHERE tr.refund_amount > 0
      AND tr.sales_order_id IN (
          SELECT sales_order_id FROM tickets
          WHERE sales_order_id IS NOT NULL
      )
    GROUP BY tr.sales_order_id
),

-- ============================================================
-- NOTES (aggregated per ticket, excluding system notes)
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
    FROM [NetSuite].[dbo].[silver_Transaction] nt
    WHERE nt.TransactionType    = 'Sales Order'
      AND nt.TransactionLineID != 0
      AND nt.TransactionDisplayName COLLATE Latin1_General_100_BIN2_UTF8 IN (
          SELECT ('Sales Order #' + sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
          FROM tickets
          WHERE sales_order_id IS NOT NULL
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
    FROM [DWH].[dbo].[DimEmployee] de
    WHERE de.Email IS NOT NULL
),

-- ============================================================
-- HUBSPOT CONTACT ID (two-path: person_id → CVPersonID, fallback email)
-- ============================================================

hubspot_person AS (
    SELECT
        hc.CVPersonID  COLLATE Latin1_General_100_BIN2_UTF8 AS CVPersonID,
        hc.ContactID
    FROM [HubSpot].[dbo].[silver_Contacts] hc
    WHERE hc.CVPersonID IS NOT NULL
),

hubspot_email AS (
    SELECT
        LOWER(hc.Email) COLLATE Latin1_General_100_BIN2_UTF8 AS Email,
        hc.ContactID
    FROM [HubSpot].[dbo].[silver_Contacts] hc
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
        FROM [tenxhub].[ticket-manager].[history] h
        WHERE h.action = 'Confirmation status updated'
          AND h.changed_by NOT IN ('System', 'bulk-import')
          AND h.ticket_id IN (
              SELECT ticket_id FROM tickets
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
--   1. POS path: original event = current event → POS, different → Concierge
--   2. Status changed to undecided (history) → Concierge
--   3. undecided_timestamp populated → Concierge
--   4. Reschedule history (both old+new values) → Concierge
--   5. Default → POS
--
-- Removed: human-touched history_concierge (unreliable — tech team does
--   Concierge work via bulk-import/service, can't distinguish by actor)
-- Added: undecided_timestamp + Status changed to undecided (direct evidence)
--
-- Seat Attribution logic (true comp first, then reschedule, then POS/Concierge):
--   is_comped = 1 + no sales order + reschedule → Rescheduled + Comp
--   is_comped = 1 + no sales order + no reschedule → Comp
--   reschedule + was undecided → Rescheduled + Undecided
--   reschedule + not undecided → Rescheduled
--   POS → Sales (comped with sales order flows here too)
--   Concierge + everything else → Undecided
-- Note: Comp Type column still shows ALL comps for visibility
-- ============================================================

-- Step 1: Get original purchased event date from POS
-- Chain: tenxhub → NetSuite → bronze_OrdersFULL → bronze_OrdersSelectedEventsFULL → silver_Events
pos_original_event AS (
    SELECT
        t.ticket_id,
        pos_evt.StartDate AS original_event_date
    FROM tickets t
    INNER JOIN (
        SELECT DISTINCT
            TransactionID,
            TransactionDisplayName
        FROM [NetSuite].[dbo].[silver_Transaction]
        WHERE TransactionType = 'Sales Order'
          AND TransactionLineID = 0
    ) ns_link
        ON ns_link.TransactionDisplayName = CONCAT('Sales Order #', t.sales_order_id)
            COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersFULL] bof
        ON bof.sales_order_ids COLLATE Latin1_General_100_BIN2_UTF8
         = CAST(ns_link.TransactionID AS VARCHAR(20)) COLLATE Latin1_General_100_BIN2_UTF8
    INNER JOIN [POS].[dbo].[bronze_OrdersSelectedEventsFULL] bose
        ON bose.order_id = bof.order_id
            COLLATE Latin1_General_100_BIN2_UTF8
        AND bose.selected_event_name LIKE '%Elite Edge%'
    INNER JOIN [POS].[dbo].[silver_Events] pos_evt
        ON pos_evt.EventID = bose.selected_event_id
            COLLATE Latin1_General_100_BIN2_UTF8
    WHERE t.sales_order_id IS NOT NULL
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
    FROM [tenxhub].[ticket-manager].[history]
    WHERE action = 'Event assigned/unassigned'
      AND old_value IS NOT NULL AND old_value != ''
      AND new_value IS NOT NULL AND new_value != ''
),

-- Step 4: History — tickets that were in the undecided pool
-- Direct evidence: action = 'Status changed to undecided' means ticket entered the pool
history_was_undecided AS (
    SELECT DISTINCT ticket_id
    FROM [tenxhub].[ticket-manager].[history]
    WHERE action = 'Status changed to undecided'
),

-- Step 5: Source of Purchase (POS date comparison primary, undecided signals + history fallback)
-- Removed: human-touched history_concierge (unreliable — tech team does Concierge work)
-- Added: undecided_timestamp + Status changed to undecided (direct evidence of undecided pool)
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
            -- Was in undecided pool (history)
            WHEN hwu.ticket_id IS NOT NULL THEN 'Concierge'
            -- Has undecided_timestamp (direct field evidence)
            WHEN t.undecided_timestamp IS NOT NULL THEN 'Concierge'
            -- Reschedule history (both old+new values)
            WHEN hr.ticket_id IS NOT NULL THEN 'Concierge'
            -- Default
            ELSE 'POS'
        END AS source_of_purchase
    FROM tickets t
    LEFT JOIN pos_original_event_dedup poe ON t.ticket_id = poe.ticket_id
    LEFT JOIN history_rescheduled hr       ON t.ticket_id = hr.ticket_id
    LEFT JOIN history_was_undecided hwu    ON t.ticket_id = hwu.ticket_id
),

-- Step 6: Seat Attribution
-- True comp check runs FIRST (is_comped = 1 AND no sales order → Comp)
-- Comped tickets WITH a sales order flow through normal POS/Concierge logic
-- Comp Type column still shows all comps for visibility
-- Then reschedule + undecided check (was in pool AND moved between events)
-- Then POS/Concierge split for remaining tickets
seat_attribution AS (
    SELECT
        t.ticket_id,
        CASE
            -- True comp (no sales order) + reschedule = Rescheduled + Comp
            WHEN COALESCE(t.is_comped, 0) = 1 AND (t.sales_order_id IS NULL OR t.sales_order_id = '') AND hr.ticket_id IS NOT NULL THEN 'Rescheduled + Comp'
            -- True comp (no sales order) + no reschedule = Comp
            WHEN COALESCE(t.is_comped, 0) = 1 AND (t.sales_order_id IS NULL OR t.sales_order_id = '') THEN 'Comp'
            -- Not true comp + reschedule + was undecided = Rescheduled + Undecided
            WHEN hr.ticket_id IS NOT NULL AND (hwu.ticket_id IS NOT NULL OR t.undecided_timestamp IS NOT NULL) THEN 'Rescheduled + Undecided'
            -- Reschedule + not undecided = Rescheduled
            WHEN hr.ticket_id IS NOT NULL THEN 'Rescheduled'
            -- POS = Sales
            WHEN sop.source_of_purchase = 'POS' THEN 'Sales'
            -- Concierge + everything else = Undecided
            WHEN sop.source_of_purchase = 'Concierge' THEN 'Undecided'
            -- Safety default
            ELSE 'Sales'
        END AS seat_attribution
    FROM tickets t
    INNER JOIN source_of_purchase sop ON t.ticket_id = sop.ticket_id
    LEFT JOIN history_rescheduled hr  ON t.ticket_id = hr.ticket_id
    LEFT JOIN history_was_undecided hwu ON t.ticket_id = hwu.ticket_id
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
        WHEN COALESCE(t.is_comped, 0) = 1 AND t.sales_order_id IS NOT NULL THEN 'Comp - Sales Order'
        WHEN COALESCE(t.is_comped, 0) = 1 AND t.sales_order_id IS NULL     THEN 'Comp - No Sales Order'
        ELSE NULL
    END                                                         AS [Comp Type],

    -- Col 31: DATE Selection (DNT)
    t.event_date                                                AS [DATE Selection (DNT)],

    -- Col 32: HubSpot Contact ID
    COALESCE(hp.ContactID, he.ContactID)                        AS [Hubspot Contact ID],

    -- Col 33: ABR (HubSpot contact-level primary, DWH fallback via hubspot_abr, tenxhub last resort)
    COALESCE(habr.annual_business_revenue, c.abr)               AS [Annual Business Revenue],
    -- Col 34: Vertical (DWH primary, tenxhub fallback — clean names RevOps expects)
    COALESCE(dc.vertical, c.vertical)                           AS [Vertical],

    -- Col 35: Elite Status (tenxhub customers.status: 3=E125, 4=E250)
    CASE c.customer_status
        WHEN '3' THEN 'E125'
        WHEN '4' THEN 'E250'
        ELSE NULL
    END                                                         AS [Elite Status],

    -- Col 36: Vertical Summit (manual)
    NULL                                                        AS [Vertical Summit?],

    -- Col 36: Status
    t.status                                                    AS [Status],

    -- Col 37-39: Manual columns
    NULL                                                        AS [Products Sold At the Event],
    nsr.is_10x360                                               AS [10X360],
    ryb.ItemName                                                AS [RYB],
    NULL                                                        AS [TCV]

FROM tickets t

LEFT JOIN attendees a
    ON t.attendee_id = a.attendee_id

LEFT JOIN sessions s
    ON t.ticket_id = s.ticket_id

LEFT JOIN customers c
    ON t.customer_id = c.customer_id

LEFT JOIN dim_customer dc
    ON c.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8
     = dc.cv_customer_id

LEFT JOIN hubspot_abr habr
    ON c.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8
     = habr.cv_customer_id

LEFT JOIN ryb_purchases ryb
    ON c.cv_customer_id COLLATE Latin1_General_100_BIN2_UTF8
     = ryb.cv_customer_id

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
