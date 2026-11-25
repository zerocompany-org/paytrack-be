-- =============================================================================
-- Đổ dữ liệu từ VPS cũ sang Postgres HA — BƯỚC 1: chạy SAU khi restore
-- backup.sql và TRƯỚC khi start pod paytrack-be lần đầu.
--
--   psql ... -d paytrack -v ON_ERROR_STOP=1 -f backup.sql
--   psql ... -d paytrack -v ON_ERROR_STOP=1 -f legacy-01-before-boot.sql   <-- file này
--   kubectl apply -k .            (pod boot, autoMigrate thêm cột mới)
--   psql ... -d paytrack -v ON_ERROR_STOP=1 -f legacy-02-after-boot.sql
--
-- Đã kiểm thử với backup.sql (23 users / 73 payments / 14 projects /
-- 10 user_timer / 5 approver_settings) trên Postgres 17 + đúng code hiện tại.
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. payments.payment_method: bigint -> text
--
-- Code đã đổi `utils.Method` từ int sang string (utils/payment.go), nhưng DB cũ
-- vẫn lưu số. KHÔNG được để autoMigrate tự đổi: GORM sẽ chạy
-- `ALTER COLUMN ... TYPE text` không kèm USING, Postgres cast số sang text theo
-- nghĩa chữ nên dữ liệu thành '0'/'1'/'3' — pod vẫn chạy, không có log lỗi,
-- nhưng mọi payment hiện ra "không có phương thức". Đây là lỗi âm thầm, phải
-- xử lý trước.
--
-- Bảng mã lấy từ cmd/migrate-method-int-to-string/main.go.
-- -----------------------------------------------------------------------------
ALTER TABLE payments
  ALTER COLUMN payment_method TYPE text
  USING CASE payment_method
          WHEN 0 THEN ''      -- PaymentTypeNotSet
          WHEN 1 THEN 'btc'
          WHEN 2 THEN 'ltc'
          WHEN 3 THEN 'dcr'
          ELSE ''
        END;

-- -----------------------------------------------------------------------------
-- 2. Nạp lại sequence
--
-- backup.sql tạo sequence bằng `CREATE SEQUENCE ... START WITH 1` rồi insert id
-- tường minh, nên sequence chưa hề được gọi: nextval() trả về 1.
-- Không có bước này thì user/payment/project MỚI tạo sẽ chết ngay với
-- `duplicate key value violates unique constraint "users_pkey"` — đã dựng lại
-- đúng lỗi này khi kiểm thử.
--
-- `false` ở tham số thứ 3 = giá trị vừa set CHƯA dùng, nên nextval() trả về
-- đúng max(id)+1.
-- -----------------------------------------------------------------------------
SELECT setval('users_id_seq',             COALESCE((SELECT max(id)         FROM users),             0) + 1, false);
SELECT setval('payments_id_seq',          COALESCE((SELECT max(id)         FROM payments),          0) + 1, false);
SELECT setval('projects_project_id_seq',  COALESCE((SELECT max(project_id) FROM projects),          0) + 1, false);
SELECT setval('user_timer_id_seq',        COALESCE((SELECT max(id)         FROM user_timer),        0) + 1, false);
SELECT setval('approver_settings_id_seq', COALESCE((SELECT max(id)         FROM approver_settings), 0) + 1, false);

-- -----------------------------------------------------------------------------
-- 3. Gắn sequence vào cột (OWNED BY)
--
-- backup.sql tạo sequence rời, không thuộc cột nào: `pg_get_serial_sequence`
-- trả về NULL. Hệ quả: pg_dump sau này KHÔNG mang theo giá trị sequence, lần
-- restore kế tiếp lại gặp đúng lỗi trùng khoá ở trên. Gắn OWNED BY một lần cho
-- hết chuyện.
-- -----------------------------------------------------------------------------
ALTER SEQUENCE users_id_seq             OWNED BY users.id;
ALTER SEQUENCE payments_id_seq          OWNED BY payments.id;
ALTER SEQUENCE projects_project_id_seq  OWNED BY projects.project_id;
ALTER SEQUENCE user_timer_id_seq        OWNED BY user_timer.id;
ALTER SEQUENCE approver_settings_id_seq OWNED BY approver_settings.id;

COMMIT;

-- Kiểm tra nhanh sau khi chạy:
--   SELECT payment_method, count(*) FROM payments GROUP BY 1;
--     -> phải ra '', 'btc', 'dcr' (KHÔNG phải '0','1','3')
--   SELECT last_value FROM users_id_seq;   -> phải = max(id)+1

-- =============================================================================
-- CHỮA CHÁY: nếu pod đã boot TRƯỚC khi chạy file này thì autoMigrate đã đổi
-- payment_method sang text với giá trị '0'/'1'/'3'. Câu ALTER ở trên lúc đó
-- không dùng được nữa (cột đã là text). Chạy câu này thay thế:
--
--   UPDATE payments SET payment_method = CASE payment_method
--            WHEN '0' THEN ''
--            WHEN '1' THEN 'btc'
--            WHEN '2' THEN 'ltc'
--            WHEN '3' THEN 'dcr'
--            ELSE payment_method
--          END
--    WHERE payment_method IN ('0','1','2','3');
--
-- Phần setval/OWNED BY ở trên vẫn chạy bình thường, không phụ thuộc thứ tự.
-- =============================================================================
