-- =====================================================
-- KIỂM SOÁT GIAO DỊCH CẤP PHÁT THUỐC - Stored Procedure DispenseMedicine
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_tx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_tx;

DROP TABLE IF EXISTS Medicines;
DROP TABLE IF EXISTS Patient_Invoices;

CREATE TABLE Medicines (
    medicine_id   INT PRIMARY KEY,
    medicine_name VARCHAR(100)   NOT NULL,
    price         DECIMAL(12, 2) NOT NULL,
    stock         INT            NOT NULL DEFAULT 0
) ENGINE = InnoDB;

CREATE TABLE Patient_Invoices (
    patient_id INT PRIMARY KEY,
    total_due  DECIMAL(15, 2) NOT NULL DEFAULT 0
) ENGINE = InnoDB;

INSERT INTO Medicines (medicine_id, medicine_name, price, stock) VALUES
    (1, 'Paracetamol 500mg', 5000,  100),
    (2, 'Amoxicillin 250mg', 12000, 5),
    (3, 'Vitamin C 1000mg',  3000,  200);

INSERT INTO Patient_Invoices (patient_id, total_due) VALUES
    (1, 0),
    (2, 50000);

-- =====================================================
-- 1. STORED PROCEDURE DispenseMedicine
-- =====================================================
DROP PROCEDURE IF EXISTS DispenseMedicine;

DELIMITER //

CREATE PROCEDURE DispenseMedicine(
    IN  p_patient_id  INT,
    IN  p_medicine_id INT,
    IN  p_quantity    INT,
    OUT p_message     VARCHAR(255)
)
proc: BEGIN
    DECLARE v_stock INT            DEFAULT NULL;
    DECLARE v_price DECIMAL(12, 2) DEFAULT NULL;

    -- Lỗi hệ thống bất ngờ: hoàn tác toàn bộ, trả thông báo thay vì để lỗi văng ra ngoài
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'Lỗi: Hệ thống gặp sự cố, giao dịch đã bị hủy';
    END;

    -- Kiểm tra đầu vào trước khi mở giao dịch
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SET p_message = 'Lỗi: Số lượng cấp phát phải lớn hơn 0';
        LEAVE proc;
    END IF;

    START TRANSACTION;

    -- Đọc tồn kho và đơn giá, khóa dòng thuốc để không ai cấp phát cùng lúc
    SELECT stock, price INTO v_stock, v_price
    FROM Medicines
    WHERE medicine_id = p_medicine_id
    FOR UPDATE;

    IF v_stock IS NULL THEN
        ROLLBACK;
        SET p_message = 'Lỗi: Không tìm thấy thuốc';
        LEAVE proc;
    END IF;

    IF v_stock < p_quantity THEN
        ROLLBACK;
        SET p_message = 'Lỗi: Số lượng tồn kho không đủ';
        LEAVE proc;
    END IF;

    -- Thao tác 'Kho': trừ số lượng cấp phát
    UPDATE Medicines
    SET stock = stock - p_quantity
    WHERE medicine_id = p_medicine_id;

    -- Thao tác 'Công nợ': cộng thành tiền vào công nợ (tạo mới nếu bệnh nhân chưa có dòng công nợ)
    INSERT INTO Patient_Invoices (patient_id, total_due)
    VALUES (p_patient_id, p_quantity * v_price)
    ON DUPLICATE KEY UPDATE total_due = total_due + p_quantity * v_price;

    COMMIT;
    SET p_message = 'Đã cấp phát thành công';
END //

DELIMITER ;

-- =====================================================
-- 2. KIỂM THỬ
-- =====================================================
-- Trường hợp 1: cấp phát hợp lệ - bệnh nhân 1 lấy 10 viên Paracetamol (tồn 100)
CALL DispenseMedicine(1, 1, 10, @msg);
SELECT @msg AS message;

-- Trường hợp 2: vượt tồn kho - bệnh nhân 2 lấy 10 viên Amoxicillin (tồn 5)
CALL DispenseMedicine(2, 2, 10, @msg);
SELECT @msg AS message;

-- Kiểm tra dữ liệu sau 2 lần gọi
SELECT medicine_id, medicine_name, stock FROM Medicines;
SELECT patient_id, total_due FROM Patient_Invoices;
