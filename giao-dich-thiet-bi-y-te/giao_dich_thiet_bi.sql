-- =====================================================
-- TỰ ĐỘNG HÓA GIAO DỊCH THIẾT BỊ Y TẾ - Stored Procedure ProcessEquipmentPurchase
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_tx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_tx;

DROP TABLE IF EXISTS Products;
DROP TABLE IF EXISTS Wallets;

CREATE TABLE Products (
    product_id     INT PRIMARY KEY,
    product_name   VARCHAR(100)   NOT NULL,
    price          DECIMAL(15, 2) NOT NULL,
    stock_quantity INT            NOT NULL DEFAULT 0
) ENGINE = InnoDB;

CREATE TABLE Wallets (
    wallet_id  INT PRIMARY KEY,
    patient_id INT            NOT NULL UNIQUE,
    balance    DECIMAL(15, 2) NOT NULL DEFAULT 0,
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active'    -- Active / Inactive
) ENGINE = InnoDB;

INSERT INTO Products (product_id, product_name, price, stock_quantity) VALUES
    (1, 'May do huyet ap',    850000,  10),
    (2, 'Nhiet ke dien tu',   120000,   2),
    (3, 'May do duong huyet', 1500000,  5);

INSERT INTO Wallets (wallet_id, patient_id, balance, status) VALUES
    (1, 1, 3000000, 'Active'),     -- ví hợp lệ
    (2, 2,  200000, 'Active'),     -- ví ít tiền
    (3, 3, 5000000, 'Inactive');   -- ví bị khóa

-- =====================================================
-- 1. STORED PROCEDURE ProcessEquipmentPurchase
-- =====================================================
DROP PROCEDURE IF EXISTS ProcessEquipmentPurchase;

DELIMITER //

CREATE PROCEDURE ProcessEquipmentPurchase(
    IN  p_patient_id INT,
    IN  p_product_id INT,
    IN  p_quantity   INT,
    OUT p_message    VARCHAR(255)
)
proc: BEGIN
    DECLARE v_stock         INT            DEFAULT NULL;   -- tồn kho hiện tại
    DECLARE v_price         DECIMAL(15, 2) DEFAULT NULL;   -- đơn giá
    DECLARE v_total         DECIMAL(15, 2) DEFAULT 0;      -- thành tiền
    DECLARE v_balance       DECIMAL(15, 2) DEFAULT NULL;   -- số dư ví
    DECLARE v_wallet_status VARCHAR(20)    DEFAULT NULL;   -- trạng thái ví

    -- Lỗi hệ thống bất ngờ (rớt kết nối...) -> hủy toàn bộ
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'Thất bại: Lỗi hệ thống, giao dịch đã được hoàn tác';
    END;

    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        SET p_message = 'Thất bại: Số lượng mua không hợp lệ';
        LEAVE proc;
    END IF;

    START TRANSACTION;

    -- Đọc và khóa dòng sản phẩm
    SELECT stock_quantity, price INTO v_stock, v_price
    FROM Products
    WHERE product_id = p_product_id
    FOR UPDATE;

    IF v_stock IS NULL THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Sản phẩm không tồn tại';
        LEAVE proc;
    END IF;

    -- Ràng buộc Out of stock
    IF v_stock < p_quantity THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Kho không đủ sản phẩm';
        LEAVE proc;
    END IF;

    -- Tính Thành tiền = Số lượng * Đơn giá
    SET v_total = p_quantity * v_price;

    -- Đọc và khóa dòng ví
    SELECT balance, status INTO v_balance, v_wallet_status
    FROM Wallets
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    IF v_wallet_status IS NULL THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Bệnh nhân chưa có ví';
        LEAVE proc;
    END IF;

    -- Ràng buộc Locked Account
    IF v_wallet_status = 'Inactive' THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Ví đang bị khóa';
        LEAVE proc;
    END IF;

    -- Ràng buộc Insufficient funds
    IF v_balance < v_total THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Số dư ví không đủ';
        LEAVE proc;
    END IF;

    -- Trừ số lượng thiết bị
    UPDATE Products
    SET stock_quantity = stock_quantity - p_quantity
    WHERE product_id = p_product_id;

    -- Trừ Thành tiền vào ví
    UPDATE Wallets
    SET balance = balance - v_total
    WHERE patient_id = p_patient_id;

    COMMIT;
    SET p_message = 'Thành công: Đã xử lý đơn hàng';
END //

DELIMITER ;

-- =====================================================
-- 2. KIỂM THỬ
-- =====================================================
-- (1) Mua hàng hợp lệ: BN 1 mua 2 máy đo huyết áp (2 x 850.000 = 1.700.000)
CALL ProcessEquipmentPurchase(1, 1, 2, @msg);
SELECT @msg AS message;

-- (2) Lỗi Out of stock: BN 1 mua 5 nhiệt kế (kho còn 2)
CALL ProcessEquipmentPurchase(1, 2, 5, @msg);
SELECT @msg AS message;

-- (3) Lỗi Insufficient funds: BN 2 (ví 200.000) mua 1 máy đo đường huyết (1.500.000)
CALL ProcessEquipmentPurchase(2, 3, 1, @msg);
SELECT @msg AS message;

-- (4) Lỗi Locked Account: BN 3 (ví Inactive) mua 1 máy đo huyết áp
CALL ProcessEquipmentPurchase(3, 1, 1, @msg);
SELECT @msg AS message;

-- Kiểm tra dữ liệu: chỉ giao dịch (1) làm thay đổi kho và ví
SELECT product_id, product_name, stock_quantity FROM Products;
SELECT patient_id, balance, status FROM Wallets;
