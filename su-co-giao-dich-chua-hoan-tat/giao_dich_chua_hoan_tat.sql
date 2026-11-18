-- =====================================================
-- SỰ CỐ GIAO DỊCH CHƯA HOÀN TẤT - Stored Procedure PayHospitalFee
-- Lưu ý: file có các lệnh CALL cố ý gây lỗi ([LỖI DỰ KIẾN]).
-- Trong MySQL Workbench, tắt Query > "Stop Script Execution on Errors" để chạy hết file
-- (hoặc chạy bằng: mysql --force < giao_dich_chua_hoan_tat.sql).
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
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active'
) ENGINE = InnoDB;

CREATE TABLE Patient_Invoices (
    patient_id INT PRIMARY KEY,
    total_due  DECIMAL(15, 2) NOT NULL DEFAULT 0
) ENGINE = InnoDB;

INSERT INTO Wallets (wallet_id, patient_id, balance) VALUES
    (1, 1, 1000000),
    (2, 2,  200000);

INSERT INTO Patient_Invoices (patient_id, total_due) VALUES
    (1, 500000),
    (2, 300000);

-- =====================================================
-- MÃ NGUỒN CŨ
-- =====================================================
DROP PROCEDURE IF EXISTS PayHospitalFee;

DELIMITER //

CREATE PROCEDURE PayHospitalFee(IN p_patient_id INT, IN p_amount DECIMAL(10, 2))
BEGIN
    -- Bước 1: Trừ tiền trong ví
    UPDATE Wallets SET balance = balance - p_amount WHERE patient_id = p_patient_id;

    -- Giả lập sự cố hệ thống bất ngờ xảy ra tại đây (cúp điện, rớt mạng...)
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Hệ thống gặp sự cố mạng đột ngột!';

    -- Bước 2: Giảm trừ công nợ (dòng này không kịp chạy)
    UPDATE Patient_Invoices SET total_due = total_due - p_amount WHERE patient_id = p_patient_id;
END //

DELIMITER ;

-- =====================================================
-- PHẦN A - TÁI HIỆN LỖI
-- =====================================================
-- [LỖI DỰ KIẾN] Error Code: 1644. Lỗi: Hệ thống gặp sự cố mạng đột ngột!
CALL PayHospitalFee(1, 500000);

SELECT w.patient_id, w.balance, i.total_due
FROM Wallets AS w
INNER JOIN Patient_Invoices AS i ON i.patient_id = w.patient_id
WHERE w.patient_id = 1;
-- Kết quả: balance = 500000 (đã bị trừ), total_due = 500000 (không giảm) -> bệnh nhân mất tiền oan

-- Khôi phục dữ liệu bị sai trước khi sửa thủ tục
UPDATE Wallets SET balance = 1000000 WHERE patient_id = 1;

-- =====================================================
-- PHẦN B - SỬA CHỮA MÃ NGUỒN
-- =====================================================
DROP PROCEDURE IF EXISTS PayHospitalFee;

DELIMITER //

CREATE PROCEDURE PayHospitalFee(IN p_patient_id INT, IN p_amount DECIMAL(10, 2))
BEGIN
    DECLARE v_balance DECIMAL(15, 2) DEFAULT NULL;

    -- Bất kỳ lỗi nào xảy ra giữa chừng: hoàn tác toàn bộ rồi báo lỗi lại cho người gọi
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Khóa dòng ví để không giao dịch nào khác trừ tiền cùng lúc
    SELECT balance INTO v_balance
    FROM Wallets
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    IF v_balance IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Bệnh nhân chưa có ví trả trước';
    ELSEIF p_amount <= 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Số tiền thanh toán không hợp lệ';
    ELSEIF v_balance < p_amount THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Số dư ví không đủ để thanh toán';
    END IF;

    -- Bước 1: Trừ tiền trong ví
    UPDATE Wallets SET balance = balance - p_amount WHERE patient_id = p_patient_id;

    -- Giả lập sự cố: chỉ xảy ra khi bật biến phiên @simulate_network_error = 1 (phục vụ kiểm thử)
    IF @simulate_network_error = 1 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Lỗi: Hệ thống gặp sự cố mạng đột ngột!';
    END IF;

    -- Bước 2: Giảm trừ công nợ
    UPDATE Patient_Invoices SET total_due = total_due - p_amount WHERE patient_id = p_patient_id;

    COMMIT;
END //

DELIMITER ;

-- =====================================================
-- KIỂM THỬ
-- =====================================================
-- Test 1 [LỖI DỰ KIẾN]: sự cố xảy ra giữa 2 bước -> toàn bộ bị hoàn tác
SET @simulate_network_error = 1;
CALL PayHospitalFee(1, 500000);

SELECT w.patient_id, w.balance, i.total_due
FROM Wallets AS w
INNER JOIN Patient_Invoices AS i ON i.patient_id = w.patient_id
WHERE w.patient_id = 1;
-- Kết quả: balance = 1000000 (đã được hoàn lại), total_due = 500000

-- Test 2: hệ thống bình thường -> cả 2 bước cùng thành công
SET @simulate_network_error = 0;
CALL PayHospitalFee(1, 500000);

SELECT w.patient_id, w.balance, i.total_due
FROM Wallets AS w
INNER JOIN Patient_Invoices AS i ON i.patient_id = w.patient_id
WHERE w.patient_id = 1;
-- Kết quả: balance = 500000, total_due = 0
