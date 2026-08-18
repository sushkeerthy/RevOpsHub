CREATE VIEW [DWH].[vw_revops_appscript] AS

WITH

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
    FROM [tenxhub].[ticket-manager].[tickets] t
    WHERE t.product_name LIKE '%Elite Edge%'
      AND t.status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
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
        FROM [tenxhub].[ticket-manager].[attendee_ticket_sessions] ats
        JOIN [tenxhub].[ticket-manager].[attendee_tickets] at
            ON ats.attendee_ticket_id = at.attendee_ticket_id
        LEFT JOIN [Profisee].[dbo].[silver_EventSession] es
            ON ats.event_session_code COLLATE Latin1_General_100_BIN2_UTF8
             = es.CVEventSessionID    COLLATE Latin1_General_100_BIN2_UTF8
        WHERE at.attendee_id IN (
            SELECT attendee_id FROM [tenxhub].[ticket-manager].[tickets]
            WHERE product_name LIKE '%Elite Edge%'
              AND status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
        )
    ) x
    WHERE room_type IS NOT NULL
    GROUP BY attendee_id
),

customers AS (
    SELECT
        c.id              AS customer_id,
        c.name            AS company_name,
        c.cv_customer_id,
        c.status          AS customer_status
    FROM [tenxhub].[ticket-manager].[customers] c
),

dim_customer AS (
    SELECT
        dc.CVCustomerID
            COLLATE Latin1_General_100_BIN2_UTF8  AS cv_customer_id,
        dc.VerticalName                           AS vertical,
        dc.AnnualBusinessRevenueName              AS annual_business_revenue
    FROM [DWH].[dbo].[DimCustomer] dc
    WHERE dc.CVCustomerID IS NOT NULL
),

refunds AS (
    SELECT
        tr.sales_order_id,
        CASE
            WHEN tr.refund_amount > 0 THEN 'Yes - ' + tr.refund_reason
            ELSE NULL
        END AS refund_request
    FROM [tenxhub].[ticket-manager].[transactions] tr
    WHERE tr.refund_amount > 0
      AND tr.sales_order_id IN (
          SELECT sales_order_id FROM [tenxhub].[ticket-manager].[tickets]
          WHERE product_name LIKE '%Elite Edge%'
            AND status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
            AND sales_order_id IS NOT NULL
      )
),

ticket_notes AS (
    SELECT
        n.ticket_id,
        STRING_AGG(
            CONVERT(VARCHAR(MAX), n.note),
            ' | '
        ) WITHIN GROUP (ORDER BY n.created_at DESC) AS notes
    FROM [tenxhub].[ticket-manager].[notes] n
    WHERE n.ticket_id IN (
        SELECT ticket_id FROM [tenxhub].[ticket-manager].[tickets]
        WHERE product_name LIKE '%Elite Edge%'
          AND status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
    )
      AND n.note NOT IN ('Created from POS', 'Created from Fabric')
    GROUP BY n.ticket_id
),

netsuite AS (
    SELECT
        nt.TransactionDisplayName
            COLLATE Latin1_General_100_BIN2_UTF8          AS TransactionDisplayName,
        CAST(MIN(nt.TransactionID) AS VARCHAR(50))
            COLLATE Latin1_General_100_BIN2_UTF8          AS TransactionID,
        MIN(nt.TransactionDate)                           AS date_of_purchase,
        MAX(CASE WHEN nt.ClassName = '10X360' THEN 'Yes'
                 ELSE NULL END)                           AS is_10x360
    FROM [NetSuite].[dbo].[silver_Transaction] nt
    WHERE nt.TransactionType    = 'Sales Order'
      AND nt.TransactionLineID != 0
      AND nt.TransactionDisplayName COLLATE Latin1_General_100_BIN2_UTF8 IN (
          SELECT ('Sales Order #' + sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
          FROM [tenxhub].[ticket-manager].[tickets]
          WHERE product_name LIKE '%Elite Edge%'
            AND status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
            AND sales_order_id IS NOT NULL
      )
    GROUP BY nt.TransactionDisplayName
),

pos_bridge AS (
    SELECT
        CAST(b.NSTransactionID AS VARCHAR(50))
            COLLATE Latin1_General_100_BIN2_UTF8  AS NSTransactionID,
        b.OrderID
            COLLATE Latin1_General_100_BIN2_UTF8  AS OrderID
    FROM [POS].[dbo].[silver_OrdersNSBridge] b
),

pos_orders AS (
    SELECT
        po.OrderID
            COLLATE Latin1_General_100_BIN2_UTF8  AS OrderID,
        po.SalesRepEmail,
        po.SalesRepName,
        po.SalesRep2Email,
        po.SalesRep2Name
    FROM [POS].[dbo].[silver_Orders] po
),

hubspot_person AS (
    SELECT
        sc.CVPersonID
            COLLATE Latin1_General_100_BIN2_UTF8  AS CVPersonID,
        sc.ContactID                              AS hubspot_contact_id
    FROM [Hubspot].[dbo].[silver_Contacts] sc
    WHERE sc.CVPersonID IS NOT NULL
),

hubspot_email AS (
    SELECT
        Email
            COLLATE Latin1_General_100_BIN2_UTF8  AS Email,
        MIN(ContactID)                            AS hubspot_contact_id
    FROM [Hubspot].[dbo].[silver_Contacts]
    WHERE Email IS NOT NULL
    GROUP BY Email
),

confirmed_by AS (
    SELECT
        ticket_id,
        changed_by
    FROM (
        SELECT
            h.ticket_id,
            h.changed_by,
            ROW_NUMBER() OVER (
                PARTITION BY h.ticket_id
                ORDER BY h.changed_at DESC
            ) AS rn
        FROM [tenxhub].[ticket-manager].[history] h
        WHERE h.action = 'Confirmation status updated'
          AND h.changed_by NOT IN ('System', 'bulk-import')
          AND h.ticket_id IN (
              SELECT ticket_id FROM [tenxhub].[ticket-manager].[tickets]
              WHERE product_name LIKE '%Elite Edge%'
                AND status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
          )
    ) x
    WHERE rn = 1
),

source_of_purchase AS (
    SELECT
        t.ticket_id,
        CASE
            WHEN h.action IN ('Event assigned', 'Event unassigned')
             AND h.old_value IS NOT NULL
             AND h.new_value IS NOT NULL
            THEN 'Concierge'
            WHEN t.is_comped = 0 THEN 'POS'
            WHEN t.is_comped = 1 THEN 'Others'
            ELSE NULL
        END AS source_of_purchase
    FROM [tenxhub].[ticket-manager].[tickets] t
    LEFT JOIN (
        SELECT
            ticket_id,
            action,
            old_value,
            new_value,
            ROW_NUMBER() OVER (
                PARTITION BY ticket_id
                ORDER BY changed_at DESC
            ) AS rn
        FROM [tenxhub].[ticket-manager].[history]
        WHERE action IN ('Event assigned', 'Event unassigned')
    ) h ON t.ticket_id = h.ticket_id AND h.rn = 1
    WHERE t.product_name LIKE '%Elite Edge%'
      AND t.status IN ('Scheduled', 'Attended', 'No Show', 'assigned')
)

SELECT
    FORMAT(t.event_date, 'MMMM dd') + '-' +
        FORMAT(DATEADD(DAY, 2, t.event_date), 'dd')        AS [Tab Name],
    t.product_name                                          AS [Product],
    t.ticket_type                                           AS [Ticket Type],
    s.room_origination                                      AS [Room Origination - Addition Effort],
    a.attendee_name                                         AS [Attendee Full Name],
    TRIM(LEFT(
        a.attendee_name,
        CHARINDEX(' ', a.attendee_name + ' ') - 1
    ))                                                      AS [First Name],
    TRIM(SUBSTRING(
        a.attendee_name,
        CHARINDEX(' ', a.attendee_name + ' ') + 1,
        LEN(a.attendee_name)
    ))                                                      AS [Last Name],
    a.attendee_email                                        AS [Attendee Email],
    a.attendee_phone                                        AS [Phone Number],
    t.purchaser_email                                       AS [Customer Email],
    c.company_name                                          AS [Company Name],
    ns.date_of_purchase                                     AS [Date of Purchase],
    t.event_date                                            AS [Original Event Scheduled Date],
    t.confirmation_status                                   AS [Attendance Confirmed],
    cb.changed_by                                           AS [Confirmed By],
    t.double_confirm_type                                   AS [Hotel/Flight Details],
    t.confirmation_method                                   AS [Confirmation Method],
    t.confirmed_date                                        AS [Confirmation Date],
    NULL                                                    AS [Blast Date],
    t.outreach_restriction                                  AS [Do not contact],
    NULL                                                    AS [Last Called Date],
    tn.notes                                                AS [Notes],
    a.dietary_restrictions                                  AS [Dietary Restrictions],
    r.refund_request                                        AS [Refund Request],
    t.ticket_price                                          AS [Price],
    po.SalesRepEmail                                        AS [Sales Person 1],
    po.SalesRepName                                         AS [Sales Person 1 Name],
    po.SalesRep2Email                                       AS [Sales Person 2],
    po.SalesRep2Name                                        AS [Sales Person 2 Name],
    sop.source_of_purchase                                  AS [Source of Purchase],
    t.event_date                                            AS [DATE Selection (DNT)],
    COALESCE(hp.hubspot_contact_id, he.hubspot_contact_id)  AS [Hubspot Contact ID],
    dc.annual_business_revenue                              AS [Annual Business Revenue],
    dc.vertical                                             AS [Vertical],
    CASE c.customer_status
        WHEN 3 THEN 'E125'
        WHEN 4 THEN 'E250'
        ELSE CAST(c.customer_status AS VARCHAR(50))
    END                                                     AS [Elite Status],
    NULL                                                    AS [Vertical Summit?],
    t.status                                                AS [Status],
    NULL                                                    AS [Products Sold At the Event],
    ns.is_10x360                                            AS [10X360],
    NULL                                                    AS [TCV]

FROM tickets t
LEFT JOIN attendees a            ON t.attendee_id    = a.attendee_id
LEFT JOIN sessions s             ON t.attendee_id    = s.attendee_id
LEFT JOIN customers c            ON t.customer_id    = c.customer_id
LEFT JOIN dim_customer dc        ON c.cv_customer_id = dc.cv_customer_id
LEFT JOIN refunds r              ON t.sales_order_id = r.sales_order_id
LEFT JOIN ticket_notes tn        ON t.ticket_id      = tn.ticket_id
LEFT JOIN netsuite ns
    ON ('Sales Order #' + t.sales_order_id) COLLATE Latin1_General_100_BIN2_UTF8
     = ns.TransactionDisplayName
LEFT JOIN pos_bridge pb          ON ns.TransactionID  = pb.NSTransactionID
LEFT JOIN pos_orders po          ON pb.OrderID        = po.OrderID
LEFT JOIN hubspot_person hp      ON a.person_id       = hp.CVPersonID
LEFT JOIN hubspot_email he       ON LOWER(a.attendee_email) = LOWER(he.Email)
LEFT JOIN confirmed_by cb        ON t.ticket_id       = cb.ticket_id
LEFT JOIN source_of_purchase sop ON t.ticket_id       = sop.ticket_id

ORDER BY
    t.event_date,
    c.company_name,
    a.attendee_name;
