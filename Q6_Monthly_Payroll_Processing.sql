-- =====================================================================
-- ICT371 Advanced Database | Question 6: Monthly Payroll Processing
-- Target DBMS: PostgreSQL 14+ (PL/pgSQL). Scheduling uses the pg_cron extension.
-- Run with:  psql -d your_database -f Q6_Monthly_Payroll_Processing.sql
-- gross = basic_salary + allowance ; net = gross - deduction
-- =====================================================================

-- ---------------------------------------------------------------------
-- (a) Database and seed data
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

CREATE TABLE employees (
    employee_id   SERIAL        PRIMARY KEY,
    full_name     VARCHAR(100)  NOT NULL,
    basic_salary  NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance     NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
    deduction     NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
    active        BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id   SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees (employee_id),
    pay_month    DATE          NOT NULL,
    gross_pay    NUMERIC(12,2) NOT NULL,
    net_pay      NUMERIC(12,2) NOT NULL,
    CONSTRAINT ck_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id     SERIAL        PRIMARY KEY,
    employee_id  INTEGER       NOT NULL REFERENCES employees (employee_id),
    old_salary   NUMERIC(12,2) NOT NULL,
    new_salary   NUMERIC(12,2) NOT NULL,
    changed_at   TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Lombe Chilufya',  8000.00, 1500.00, 1200.00, TRUE),
    ('Mutale Zimba',    6500.00, 1000.00,  900.00, TRUE),
    ('Bwalya Mumba',    5000.00,  800.00,  700.00, TRUE),
    ('Chanda Kapaya',   7000.00, 1200.00, 1000.00, TRUE),   -- becomes inactive later
    ('Nkandu Sichone',  4500.00,  500.00,  600.00, FALSE);  -- inactive from the start

-- ---------------------------------------------------------------------
-- (b) Function fn_net_pay
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_deduc NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
    INTO v_basic, v_allow, v_deduc
    FROM employees
    WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_deduc;

    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- (c) Procedure pr_process_payroll
--     A query FOR loop over active employees. Because the whole CALL is one
--     transaction, an exception from fn_net_pay undoes every row inserted so far.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    r       RECORD;
    v_gross NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'Payroll month must be the first day of a month, got %', p_month;
    END IF;

    FOR r IN
        SELECT employee_id, basic_salary, allowance
        FROM employees
        WHERE active = TRUE
        ORDER BY employee_id
    LOOP
        v_net   := fn_net_pay(r.employee_id);      -- raises on invalid calculation
        v_gross := r.basic_salary + r.allowance;

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (r.employee_id, p_month, v_gross, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- (d) Trigger: log an actual basic_salary change (AFTER UPDATE, row level)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_salary_audit ON employees;
CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------------------------------------------------------------------
-- (e) View: v_payroll_report
--     INNER JOIN from payroll keeps historical rows of employees who are
--     inactive now (we do not filter on employees.active).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.employee_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id;

-- ---------------------------------------------------------------------
-- (f) Index for reports filtered by pay_month across ALL employees
--     The existing UNIQUE (employee_id, pay_month) index starts with employee_id,
--     so it cannot be used efficiently to filter on pay_month alone.
--     This index has only pay_month, so it does not duplicate it.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- ---------------------------------------------------------------------
-- (g) Scheduled job: 02:00 on the 1st of every month, for the PREVIOUS month
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'payroll_monthly_run',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- =====================================================================
-- DEMONSTRATION / TESTING
-- =====================================================================

-- Two payroll months (processed through the procedure)
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');

-- Re-processing a month does not duplicate or change rows
CALL pr_process_payroll(DATE '2026-10-01');

-- Salary change (audited) and an employee becoming inactive
UPDATE employees SET basic_salary = 5500.00 WHERE employee_id = 3;   -- audit row
UPDATE employees SET allowance = 850.00     WHERE employee_id = 3;   -- NO audit row
UPDATE employees SET active = FALSE         WHERE employee_id = 4;

SELECT * FROM salary_audit ORDER BY audit_id;       -- exactly one row
SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- (b)
SELECT fn_net_pay(1) AS net_for_employee_1;          -- 8000 + 1500 - 1200 = 8300
-- SELECT fn_net_pay(99);                            -- ERROR: Unknown employee_id

-- (c) Failing calculation aborts the whole call (run inside a transaction, then roll back)
-- BEGIN;
--   UPDATE employees SET deduction = 99999 WHERE employee_id = 2;
--   CALL pr_process_payroll(DATE '2026-11-01');     -- ERROR: Negative net pay
-- ROLLBACK;
-- CALL pr_process_payroll(DATE '2026-11-15');       -- ERROR: not first day of month

-- (e) Employee 4 is inactive but still appears in the history
SELECT * FROM v_payroll_report ORDER BY pay_month, employee_id;

-- (f) EXPLAIN (seqscan disabled only because the demo table is tiny)
SET enable_seqscan = off;
EXPLAIN
SELECT *
FROM payroll
WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active
FROM cron.job
WHERE jobname = 'payroll_monthly_run';

SELECT runid, jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'payroll_monthly_run')
ORDER BY start_time DESC;

-- To remove the job later:  SELECT cron.unschedule('payroll_monthly_run');
