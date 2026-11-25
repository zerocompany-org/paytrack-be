-- =============================================================================
-- Đổ dữ liệu từ VPS cũ — BƯỚC 2: chạy SAU khi pod paytrack-be đã boot ít nhất
-- một lần (autoMigrate phải tạo xong bảng `user_payment_methods` trước).
--
-- CHỈ CHẠY ĐÚNG MỘT LẦN. Chạy lại là nhân đôi ví của mọi người dùng
-- (không có khoá unique nào chặn).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Dựng lại ví từ users.payment_settings sang bảng user_payment_methods
--
-- Bản cũ lưu ví trong cột jsonb `users.payment_settings` ([{type, address}]).
-- Code hiện tại đọc ví từ bảng riêng `user_payment_methods` (API
-- /api/user/payment-methods, và payments.user_payment_method_id trỏ vào đây).
-- autoMigrate tạo bảng này RỖNG, nên không làm bước này thì sau khi lên k8s mọi
-- người dùng thấy danh sách ví trắng trơn và phải tự nhập lại.
--
-- Câu lệnh này tương đương `cmd/migrate-payment-settings` (Go). Đã đối chiếu
-- kết quả hai đường: giống nhau từng dòng (13/13 ví trên backup.sql hiện có),
-- nên không cần build thêm binary nào.
--
-- Map coin/network lấy từ mapPaymentTypeToCoinNetwork():
--   btc->BTC/btc, ltc->LTC/ltc, dcr->DCR/dcr, eth->ETH/erc20, usdt->USDT/erc20
-- Loại nào không nằm trong danh sách thì bỏ qua (Go cũng bỏ qua).
-- -----------------------------------------------------------------------------
INSERT INTO user_payment_methods (user_id, label, coin, network, address, created_at, updated_at)
SELECT u.id,
       'Legacy ' || upper(e->>'type') || ' wallet',
       upper(e->>'type'),
       CASE e->>'type'
         WHEN 'eth'  THEN 'erc20'
         WHEN 'usdt' THEN 'erc20'
         ELSE e->>'type'
       END,
       coalesce(e->>'address', ''),
       u.created_at,
       now()
FROM users u, jsonb_array_elements(u.payment_settings) e
WHERE u.payment_settings IS NOT NULL
  AND e->>'type' IN ('btc', 'ltc', 'dcr', 'eth', 'usdt');

-- Kiểm tra: số dòng phải bằng tổng số phần tử payment_settings của mọi user.
--   SELECT count(*) FROM user_payment_methods;
--   SELECT count(*) FROM users, jsonb_array_elements(payment_settings) e
--     WHERE payment_settings IS NOT NULL;
--
-- KHÔNG xoá users.payment_settings: code hiện tại vẫn đọc cột đó ở vài chỗ
-- (storage.PaymentSettings), hai nơi tồn tại song song.
