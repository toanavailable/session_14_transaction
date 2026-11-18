-- =====================================================
-- QUẢN LÝ CHUYỂN GIƯỜNG BỆNH NHÂN - Stored Procedure TransferBed
-- Lưu ý: file có lệnh CALL cố ý gây lỗi ([LỖI DỰ KIẾN]).
-- Trong MySQL Workbench, tắt Query > "Stop Script Execution on Errors" để chạy hết file.
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_tx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_tx;

DROP TABLE IF EXISTS Beds;

CREATE TABLE Beds (
    bed_id     INT PRIMARY KEY,
    department VARCHAR(50) NOT NULL,
    room       VARCHAR(10) NOT NULL,
    patient_id INT NULL UNIQUE          -- NULL = giường trống; UNIQUE: 1 bệnh nhân chỉ nằm 1 giường
) ENGINE = InnoDB;

INSERT INTO Beds (bed_id, department, room, patient_id) VALUES
    (101, 'Khoa Noi',  'P101', 1),      -- bệnh nhân 1 đang nằm
    (102, 'Khoa Noi',  'P101', 2),      -- bệnh nhân 2 đang nằm
    (201, 'Khoa Ngoai','P201', NULL),   -- trống
    (202, 'Khoa Ngoai','P201', NULL);   -- trống

-- =====================================================
-- MÃ NGUỒN CŨ
-- =====================================================
DROP PROCEDURE IF EXISTS TransferBed;

DELIMITER //

CREATE PROCEDURE TransferBed(IN p_patient_id INT, IN p_new_bed_id INT)
BEGIN
    -- Thao tác 1: Giải phóng giường cũ
    UPDATE Beds SET patient_id = NULL WHERE patient_id = p_patient_id;

    -- Thao tác 2: Gán giường mới
    UPDATE Beds SET patient_id = p_patient_id WHERE bed_id = p_new_bed_id;
END //

DELIMITER ;

-- Minh họa lỗ hổng: chuyển bệnh nhân 1 sang giường 999 (không tồn tại)
-- Thao tác 1 chạy xong, thao tác 2 không cập nhật dòng nào và cũng không báo lỗi
CALL TransferBed(1, 999);

SELECT bed_id, patient_id FROM Beds ORDER BY bed_id;
-- Kết quả: giường 101 trống, không giường nào có bệnh nhân 1 -> bệnh nhân bị "mất tích"

-- Khôi phục dữ liệu trước khi sửa thủ tục
UPDATE Beds SET patient_id = 1 WHERE bed_id = 101;

-- =====================================================
-- PHẦN B - SỬA CHỮA MÃ NGUỒN
-- =====================================================
DROP PROCEDURE IF EXISTS TransferBed;

DELIMITER //

CREATE PROCEDURE TransferBed(IN p_patient_id INT, IN p_new_bed_id INT)
BEGIN
    -- Có lỗi ở bất kỳ bước nào: hoàn nguyên toàn bộ rồi báo lỗi lại cho người gọi
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    -- Thao tác 1: Giải phóng giường cũ
    UPDATE Beds SET patient_id = NULL WHERE patient_id = p_patient_id;

    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Bệnh nhân hiện không nằm giường nào';
    END IF;

    -- Thao tác 2: Gán giường mới (chỉ gán khi giường tồn tại và đang trống)
    UPDATE Beds
    SET patient_id = p_patient_id
    WHERE bed_id = p_new_bed_id
      AND patient_id IS NULL;

    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Lỗi: Giường mới không tồn tại hoặc đã có bệnh nhân';
    END IF;

    COMMIT;
END //

DELIMITER ;

-- =====================================================
-- KIỂM THỬ
-- =====================================================
-- Test 1: chuyển bệnh nhân 1 sang giường trống 201 -> thành công
CALL TransferBed(1, 201);
SELECT bed_id, patient_id FROM Beds ORDER BY bed_id;
-- Kết quả: 101 trống, 201 = bệnh nhân 1

-- Test 2 [LỖI DỰ KIẾN]: chuyển bệnh nhân 2 sang giường 999 (không tồn tại)
-- Error Code: 1644. Lỗi: Giường mới không tồn tại hoặc đã có bệnh nhân
CALL TransferBed(2, 999);
SELECT bed_id, patient_id FROM Beds ORDER BY bed_id;
-- Kết quả: bệnh nhân 2 vẫn ở giường 102 (thao tác 1 đã được ROLLBACK)

-- Test 3 [LỖI DỰ KIẾN]: chuyển bệnh nhân 2 sang giường 201 đang có bệnh nhân 1
CALL TransferBed(2, 201);
SELECT bed_id, patient_id FROM Beds ORDER BY bed_id;
-- Kết quả: không có gì thay đổi
