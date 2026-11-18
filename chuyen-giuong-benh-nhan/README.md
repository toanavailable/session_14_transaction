# Quản lý chuyển giường bệnh nhân

Phân tích lỗ hổng của thủ tục `TransferBed` khiến bệnh nhân bị "mất tích" khỏi danh sách nội trú, và viết lại thủ tục với Transaction để hai bước chuyển giường luôn thành công hoặc hoàn nguyên cùng nhau.

## 1. Đề bài

- **Nghiệp vụ:** khi bệnh nhân chuyển khoa, nhân viên y tế dùng chức năng chuyển giường để cập nhật thông tin giường.
- **Quy tắc hệ thống:** chuyển giường gồm 2 bước đồng thời: (1) giải phóng giường cũ, (2) gán bệnh nhân vào giường mới. Hai bước phải là một khối giao dịch thống nhất.
- **Sự cố:** máy chủ bị treo sau khi giải phóng giường cũ nhưng trước khi gán giường mới. Bệnh nhân bị "mất tích" khỏi danh sách nội trú (cả giường cũ và mới đều trống).
- **Mã nguồn hiện tại:**

```sql
DELIMITER //
CREATE PROCEDURE TransferBed(IN p_patient_id INT, IN p_new_bed_id INT)
BEGIN
    -- Thao tác 1: Giải phóng giường cũ
    UPDATE Beds SET patient_id = NULL WHERE patient_id = p_patient_id;

    -- Thao tác 2: Gán giường mới
    UPDATE Beds SET patient_id = p_patient_id WHERE bed_id = p_new_bed_id;
END //
DELIMITER ;
```

Bảng `Beds` và dữ liệu mẫu (trong `chuyen_giuong.sql`):

```sql
CREATE TABLE Beds (
    bed_id     INT PRIMARY KEY,
    department VARCHAR(50) NOT NULL,
    room       VARCHAR(10) NOT NULL,
    patient_id INT NULL UNIQUE          -- NULL = giường trống
) ENGINE = InnoDB;

INSERT INTO Beds (bed_id, department, room, patient_id) VALUES
    (101, 'Khoa Noi',   'P101', 1),
    (102, 'Khoa Noi',   'P101', 2),
    (201, 'Khoa Ngoai', 'P201', NULL),
    (202, 'Khoa Ngoai', 'P201', NULL);
```

File `.sql` có các lệnh `CALL` cố ý gây lỗi. Để chạy hết file trong MySQL Workbench, tắt **Query → Stop Script Execution on Errors**.

## 2. Phần A – Phân tích

Việc bệnh nhân lơ lửng không có giường vi phạm tính **Atomicity (Nguyên tử)**: hai thao tác chuyển giường phải "tất cả hoặc không gì cả". Thủ tục cũ không có transaction, nên ở chế độ `autocommit` thao tác 1 được lưu vĩnh viễn ngay, và khi sự cố xảy ra không có cách nào hoàn nguyên.

Ngoài máy chủ bị treo, mã cũ còn tự gây ra lỗi này khi `p_new_bed_id` không tồn tại: thao tác 2 không cập nhật dòng nào nhưng cũng không báo lỗi.

```sql
CALL TransferBed(1, 999);
```

| bed_id | patient_id trước | patient_id sau |
|---|---|---|
| 101 | 1 | **NULL** |
| 102 | 2 | 2 |
| 201 | NULL | NULL |
| 202 | NULL | NULL |

Không giường nào còn chứa bệnh nhân 1.

## 3. Phần B – Sửa chữa mã nguồn

```sql
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
```

- **`START TRANSACTION` … `COMMIT`:** hai thao tác chỉ được lưu vĩnh viễn khi cả hai cùng xong. Nếu máy chủ treo giữa chừng, transaction chưa `COMMIT` sẽ được InnoDB tự hoàn tác khi khởi động lại.
- **`EXIT HANDLER` + `ROLLBACK`:** lỗi ở bất kỳ bước nào cũng hoàn nguyên toàn bộ thay đổi về trạng thái ban đầu, rồi `RESIGNAL` để báo lỗi cho người gọi.
- **`ROW_COUNT()`:** trả về số dòng mà lệnh `UPDATE` ngay trước đó thay đổi. Nếu bằng 0 (bệnh nhân không có giường, hoặc giường mới không tồn tại hay đang có người), thủ tục chủ động `SIGNAL` để kích hoạt `ROLLBACK`, thay vì im lặng để bệnh nhân "mất tích" như mã cũ.
- **`AND patient_id IS NULL`:** không cho gán đè lên giường đang có bệnh nhân khác.

## 4. Kiểm thử

```sql
CALL TransferBed(1, 201);   -- Test 1: sang giường trống
CALL TransferBed(2, 999);   -- Test 2: giường không tồn tại
CALL TransferBed(2, 201);   -- Test 3: giường đang có người
```

| Test | Kết quả CALL | Trạng thái giường sau đó |
|---|---|---|
| 1 | Thành công | 101 trống, **201 = bệnh nhân 1** |
| 2 | `Error Code: 1644. Lỗi: Giường mới không tồn tại hoặc đã có bệnh nhân` | Bệnh nhân 2 **vẫn ở 102**: thao tác 1 đã chạy nhưng bị `ROLLBACK` |
| 3 | `Error Code: 1644. Lỗi: Giường mới không tồn tại hoặc đã có bệnh nhân` | Không thay đổi |

Bảng `Beds` cuối cùng:

| bed_id | patient_id |
|---|---|
| 101 | NULL |
| 102 | 2 |
| 201 | 1 |
| 202 | NULL |
