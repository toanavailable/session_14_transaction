-- =====================================================
-- CHIẾN LƯỢC KIỂM SOÁT GIAO DỊCH THANH TOÁN - Stored Procedure ProcessPayment
-- Giải pháp chọn: Chiến lược 2 (Truy xuất & đối chiếu trước) + Exception Handler làm lưới an toàn
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_tx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_tx;

DROP TABLE IF EXISTS Wallets;
DROP TABLE IF EXISTS Patient_Invoices;

CREATE TABLE Wallets (
    wallet_id  INT PRIMARY KEY,
    patient_id INT            NOT NULL UNIQUE,
    balance    DECIMAL(15, 2) NOT NULL DEFAULT 0,
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active',
    CONSTRAINT chk_wallet_balance CHECK (balance >= 0)    -- chốt chặn cuối cùng ở tầng dữ liệu
) ENGINE = InnoDB;

CREATE TABLE Patient_Invoices (
    patient_id INT PRIMARY KEY,
    total_due  DECIMAL(15, 2) NOT NULL DEFAULT 0
) ENGINE = InnoDB;

INSERT INTO Wallets (wallet_id, patient_id, balance) VALUES
    (1, 1, 1000000),
    (2, 2,  100000);

INSERT INTO Patient_Invoices (patient_id, total_due) VALUES
    (1, 600000),
    (2, 300000);

-- =====================================================
-- 1. STORED PROCEDURE ProcessPayment
-- =====================================================
DROP PROCEDURE IF EXISTS ProcessPayment;

DELIMITER //

CREATE PROCEDURE ProcessPayment(
    IN  p_patient_id INT,
    IN  p_amount     DECIMAL(15, 2),
    OUT p_message    VARCHAR(255)
)
proc: BEGIN
    DECLARE v_balance DECIMAL(15, 2) DEFAULT NULL;
    DECLARE v_status  VARCHAR(20)    DEFAULT NULL;

    -- Lưới an toàn: lỗi bất ngờ (sập kết nối, vi phạm ràng buộc...) -> hoàn tác toàn bộ
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;                                          -- [HOÀN TÁC]
        SET p_message = 'Thất bại: Lỗi hệ thống, giao dịch đã được hoàn tác';
    END;

    -- Bước 1: kiểm tra đầu vào (chưa đụng tới dữ liệu)
    IF p_amount IS NULL OR p_amount <= 0 THEN
        SET p_message = 'Thất bại: Số tiền thanh toán không hợp lệ';
        LEAVE proc;
    END IF;

    START TRANSACTION;                                     -- [KHỞI TẠO]

    -- Bước 2: truy xuất và khóa dòng ví
    SELECT balance, status INTO v_balance, v_status
    FROM Wallets
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    -- Bước 3: đối chiếu dữ liệu, vi phạm quy tắc thì chủ động hoàn tác
    IF v_balance IS NULL THEN
        ROLLBACK;                                          -- [HOÀN TÁC]
        SET p_message = 'Thất bại: Không tìm thấy ví của bệnh nhân';
        LEAVE proc;
    END IF;

    IF v_status <> 'Active' THEN
        ROLLBACK;                                          -- [HOÀN TÁC]
        SET p_message = 'Thất bại: Ví đang bị khóa';
        LEAVE proc;
    END IF;

    IF v_balance < p_amount THEN
        ROLLBACK;                                          -- [HOÀN TÁC]
        SET p_message = 'Thất bại: Số dư ví không đủ';
        LEAVE proc;
    END IF;

    -- Bước 4: thực thi 2 thao tác đồng thời
    UPDATE Wallets
    SET balance = balance - p_amount
    WHERE patient_id = p_patient_id;

    UPDATE Patient_Invoices
    SET total_due = total_due - p_amount
    WHERE patient_id = p_patient_id;

    -- Bước 5: xác nhận
    COMMIT;                                                -- [XÁC NHẬN]
    SET p_message = CONCAT('Thành công: Đã thanh toán ', FORMAT(p_amount, 0), ' đồng');
END //

DELIMITER ;

-- =====================================================
-- 2. KIỂM THỬ
-- =====================================================
-- (1) Giao dịch hợp lệ: bệnh nhân 1 (ví 1.000.000) thanh toán 400.000
CALL ProcessPayment(1, 400000, @msg);
SELECT @msg AS message;

-- (2) Số dư không đủ: bệnh nhân 2 (ví 100.000) thanh toán 300.000
CALL ProcessPayment(2, 300000, @msg);
SELECT @msg AS message;

-- (3) Bẫy lỗi số tiền âm: bệnh nhân 1 thanh toán -50.000
CALL ProcessPayment(1, -50000, @msg);
SELECT @msg AS message;

-- Kiểm tra dữ liệu sau 3 lần gọi
SELECT w.patient_id, w.balance, i.total_due
FROM Wallets AS w
INNER JOIN Patient_Invoices AS i ON i.patient_id = w.patient_id
ORDER BY w.patient_id;
