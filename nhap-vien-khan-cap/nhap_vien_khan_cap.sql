-- =====================================================
-- TỰ ĐỘNG HÓA NHẬP VIỆN KHẨN CẤP
-- Procedure Master: AdmitEmergencyPatient  |  Procedure phụ: FindAvailableBed
-- =====================================================

-- 0. Dữ liệu mẫu
CREATE DATABASE IF NOT EXISTS rikkei_clinic_tx CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE rikkei_clinic_tx;

DROP TABLE IF EXISTS Appointments;
DROP TABLE IF EXISTS Beds;
DROP TABLE IF EXISTS Departments;

CREATE TABLE Departments (
    department_id   INT PRIMARY KEY,
    department_name VARCHAR(100) NOT NULL
) ENGINE = InnoDB;

CREATE TABLE Beds (
    bed_id        INT PRIMARY KEY,
    department_id INT NOT NULL,
    patient_id    INT NULL UNIQUE,        -- NULL = giường trống
    CONSTRAINT fk_bed_department FOREIGN KEY (department_id) REFERENCES Departments (department_id)
) ENGINE = InnoDB;

CREATE TABLE Appointments (
    appointment_id   INT AUTO_INCREMENT PRIMARY KEY,
    patient_id       INT         NOT NULL,
    doctor_id        INT         NOT NULL,
    department_id    INT         NOT NULL,
    appointment_time DATETIME    NOT NULL,
    status           VARCHAR(20) NOT NULL DEFAULT 'Admitted',
    CONSTRAINT fk_appt_department FOREIGN KEY (department_id) REFERENCES Departments (department_id)
) ENGINE = InnoDB;

INSERT INTO Departments (department_id, department_name) VALUES
    (1, 'Khoa Noi'),
    (2, 'Khoa Cap cuu'),
    (3, 'Khoa Ngoai');

INSERT INTO Beds (bed_id, department_id, patient_id) VALUES
    (101, 1, 10),     -- Khoa Nội: 1 giường có người
    (102, 1, NULL),   --           1 giường trống
    (201, 2, 11),     -- Khoa Cấp cứu: hết giường
    (202, 2, 12),
    (301, 3, NULL);   -- Khoa Ngoại: 1 giường trống

-- =====================================================
-- 1. PROCEDURE PHỤ: dò tìm giường trống (không mở/đóng giao dịch)
-- =====================================================
DROP PROCEDURE IF EXISTS FindAvailableBed;

DELIMITER //

CREATE PROCEDURE FindAvailableBed(
    IN  p_department_id INT,
    OUT p_bed_id        INT
)
BEGIN
    -- Không có giường trống thì trả về NULL thay vì phát sinh cảnh báo "No data"
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET p_bed_id = NULL;

    SET p_bed_id = NULL;

    -- Khóa giường được chọn: chạy bên trong giao dịch của Procedure Master
    SELECT bed_id INTO p_bed_id
    FROM Beds
    WHERE department_id = p_department_id
      AND patient_id IS NULL
    ORDER BY bed_id
    LIMIT 1
    FOR UPDATE;
END //

DELIMITER ;

-- =====================================================
-- 2. PROCEDURE MASTER: điều phối toàn bộ quy trình nhập viện
-- =====================================================
DROP PROCEDURE IF EXISTS AdmitEmergencyPatient;

DELIMITER //

CREATE PROCEDURE AdmitEmergencyPatient(
    IN  p_patient_id       INT,
    IN  p_doctor_id        INT,
    IN  p_appointment_time DATETIME,
    IN  p_department_id    INT,
    OUT p_message          VARCHAR(255)
)
proc: BEGIN
    DECLARE v_bed_id INT DEFAULT NULL;

    -- Lỗi hệ thống bất ngờ: hủy toàn bộ giao dịch
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_message = 'Thất bại: Lỗi hệ thống, giao dịch đã được hủy';
    END;

    START TRANSACTION;

    -- Chốt kiểm tra 1: khoa phải tồn tại
    IF NOT EXISTS (SELECT 1 FROM Departments WHERE department_id = p_department_id) THEN
        ROLLBACK;
        SET p_message = 'Từ chối: Khoa không tồn tại';
        LEAVE proc;
    END IF;

    -- Chốt kiểm tra 2: bệnh nhân không được đang nằm giường ở bất kỳ khoa nào
    -- (UNIQUE trên Beds.patient_id là chốt chặn cuối nếu 2 yêu cầu chạy song song)
    IF EXISTS (SELECT 1 FROM Beds WHERE patient_id = p_patient_id) THEN
        ROLLBACK;
        SET p_message = 'Từ chối: Bệnh nhân đang lưu trú';
        LEAVE proc;
    END IF;

    -- Bước 1: tạo lịch khám
    INSERT INTO Appointments (patient_id, doctor_id, department_id, appointment_time)
    VALUES (p_patient_id, p_doctor_id, p_department_id, p_appointment_time);

    -- Bước 2: gọi Procedure phụ dò tìm giường trống
    CALL FindAvailableBed(p_department_id, v_bed_id);

    -- Chốt kiểm tra 3: hết giường -> hủy cả lịch khám vừa tạo
    IF v_bed_id IS NULL THEN
        ROLLBACK;
        SET p_message = 'Từ chối: Khoa hiện đã hết giường';
        LEAVE proc;
    END IF;

    -- Bước 3: gán giường cho bệnh nhân
    UPDATE Beds
    SET patient_id = p_patient_id
    WHERE bed_id = v_bed_id;

    COMMIT;
    SET p_message = CONCAT('Thành công: Đã nhập viện, xếp giường ', v_bed_id);
END //

DELIMITER ;

-- =====================================================
-- 3. KIỂM THỬ
-- =====================================================
-- (1) Nhập viện thành công: bệnh nhân 1 vào Khoa Nội (còn giường 102)
CALL AdmitEmergencyPatient(1, 5, '2026-11-19 08:30:00', 1, @msg);
SELECT @msg AS message;

-- (2) Bẫy hết giường: bệnh nhân 2 vào Khoa Cấp cứu (đã kín giường)
CALL AdmitEmergencyPatient(2, 6, '2026-11-19 09:00:00', 2, @msg);
SELECT @msg AS message;

-- (3) Bẫy đang nội trú: bệnh nhân 1 (đang nằm giường 102) xin vào Khoa Ngoại
CALL AdmitEmergencyPatient(1, 7, '2026-11-19 09:30:00', 3, @msg);
SELECT @msg AS message;

-- (4) Chuyển vào khoa không tồn tại: bệnh nhân 3 vào khoa 99
CALL AdmitEmergencyPatient(3, 5, '2026-11-19 10:00:00', 99, @msg);
SELECT @msg AS message;

-- Kiểm tra dữ liệu: chỉ có 1 lịch khám, chỉ giường 102 thay đổi
SELECT * FROM Appointments;
SELECT bed_id, department_id, patient_id FROM Beds ORDER BY bed_id;
