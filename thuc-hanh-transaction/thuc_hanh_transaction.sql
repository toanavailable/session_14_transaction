-- =====================================================
-- BÀI THỰC HÀNH: THỰC THI VÀ KIỂM SOÁT GIAO DỊCH TRONG MYSQL
-- Lưu ý: TH2 ở cuối file cố ý gây lỗi ([LỖI DỰ KIẾN]).
-- Trong MySQL Workbench, tắt Query > "Stop Script Execution on Errors" để chạy cả lệnh SELECT cuối.
-- =====================================================

-- 0. Chuẩn bị bảng account
CREATE DATABASE IF NOT EXISTS bank_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE bank_practice;

DROP TABLE IF EXISTS account;

CREATE TABLE account (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    name    VARCHAR(100)   NOT NULL,
    balance DECIMAL(15, 2) NOT NULL DEFAULT 0
) ENGINE = InnoDB;

-- 2 tài khoản có sẵn (được lưu ngay vì autocommit đang bật)
INSERT INTO account (name, balance) VALUES
    ('Nguyễn Văn A', 1000),
    ('Trần Thị B',    200);

-- Kiểm tra chế độ autocommit hiện tại (1 = mỗi lệnh tự COMMIT)
SELECT @@autocommit;

-- =====================================================
-- BƯỚC 1: KIỂM CHỨNG LỆNH ROLLBACK
-- =====================================================
START TRANSACTION;

INSERT INTO account (name, balance) VALUES
    ('Lê Văn C',   500),
    ('Trần Thị D', 300);

-- Dữ liệu xuất hiện TẠM THỜI trong phiên làm việc này
SELECT * FROM account;

ROLLBACK;

-- 2 tài khoản 'Lê Văn C' và 'Trần Thị D' đã biến mất
SELECT * FROM account;

-- =====================================================
-- BƯỚC 2 + 3: THỦ TỤC CHUYỂN TIỀN sp_transfer_money
-- =====================================================
DROP PROCEDURE IF EXISTS sp_transfer_money;

DELIMITER //

CREATE PROCEDURE sp_transfer_money(
    IN sender_id   INT,
    IN receiver_id INT,
    IN amount      DECIMAL(15, 2)
)
BEGIN
    DECLARE v_balance DECIMAL(15, 2);

    -- Lỗi bất ngờ (sai kiểu dữ liệu, mất kết nối...) cũng phải hoàn tác
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    -- 1. Bắt đầu giao dịch
    START TRANSACTION;

    -- 2. Cộng tiền cho người nhận
    UPDATE account SET balance = balance + amount WHERE id = receiver_id;

    -- 3. Trừ tiền người gửi
    UPDATE account SET balance = balance - amount WHERE id = sender_id;

    -- 4. Lấy số dư mới nhất của người gửi
    SELECT balance INTO v_balance FROM account WHERE id = sender_id;

    -- Bước 3: logic hoàn tác
    IF v_balance < 50 THEN
        ROLLBACK;
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Giao dịch thất bại: Số dư tối thiểu phải còn 50!';
    ELSE
        COMMIT;
    END IF;
END //

DELIMITER ;

-- =====================================================
-- BƯỚC 4: THỰC THI KIỂM TRA
-- =====================================================
-- TH1 (Thành công): A chuyển 300 cho B -> A còn 700 (>= 50)
CALL sp_transfer_money(1, 2, 300);
SELECT * FROM account;
-- Kết quả: A = 700, B = 500

-- TH2 (Thất bại) [LỖI DỰ KIẾN]: A chuyển 680 cho B -> A chỉ còn 20 (< 50)
-- Error Code: 1644. Giao dịch thất bại: Số dư tối thiểu phải còn 50!
CALL sp_transfer_money(1, 2, 680);

SELECT * FROM account;
-- Kết quả: A vẫn 700, B vẫn 500 -> cả lệnh cộng tiền cho B cũng đã bị hoàn tác
