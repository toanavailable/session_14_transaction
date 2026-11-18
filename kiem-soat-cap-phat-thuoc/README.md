# Kiểm soát giao dịch cấp phát thuốc

Xây dựng thủ tục `DispenseMedicine` tự động trừ kho thuốc và cộng công nợ trong cùng một giao dịch, rồi trả về thông báo trạng thái cho màn hình.

## 1. Đề bài

- **Bối cảnh:** khi phát thuốc, dược sĩ và kế toán phải tự đối chiếu, cập nhật thủ công trên nhiều phần mềm nên dễ sai sót và lệch số liệu. Nhân viên chỉ cần nhập "Mã bệnh nhân", "Mã thuốc", "Số lượng"; hệ thống tự xử lý và trả về thông báo trạng thái.
- **Quy tắc nghiệp vụ:** xử lý đồng bộ 2 thao tác:
  - **'Kho':** trừ số lượng cấp phát trong kho thuốc.
  - **'Công nợ':** lấy số lượng nhân với đơn giá thuốc, cộng dồn vào tổng công nợ của bệnh nhân.
- **Vấn đề:** nếu số lượng nhập lớn hơn tồn kho thực tế (VD tồn 5, nhập 10), hệ thống không được cập nhật dữ liệu (tránh âm kho), phải hoàn tác toàn bộ và trả về `"Lỗi: Số lượng tồn kho không đủ"`. Nếu thành công, trả về `"Đã cấp phát thành công"`.

Bảng và dữ liệu mẫu (trong `cap_phat_thuoc.sql`):

```sql
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
```

## 2. Phân tích

### Dữ liệu vào và ra

| Tham số | Loại | Kiểu | Ý nghĩa |
|---|---|---|---|
| `p_patient_id` | `IN` | INT | Mã bệnh nhân |
| `p_medicine_id` | `IN` | INT | Mã thuốc |
| `p_quantity` | `IN` | INT | Số lượng cấp phát |
| `p_message` | `OUT` | VARCHAR(255) | Thông báo trạng thái trả về màn hình |

Dữ liệu vào chỉ cần truyền giá trị nên dùng `IN`. Thông báo trạng thái do thủ tục tạo ra và trả về cho người gọi nên dùng `OUT`; ứng dụng đọc kết quả qua biến phiên, ví dụ `CALL DispenseMedicine(1, 1, 10, @msg); SELECT @msg;`.

### Giải pháp và các bước thực hiện

1. Kiểm tra số lượng nhập vào phải lớn hơn 0 (chưa cần mở giao dịch).
2. `START TRANSACTION`.
3. Đọc tồn kho và đơn giá bằng `SELECT ... FOR UPDATE`, khóa dòng thuốc để không ai cấp phát cùng lúc.
4. Nếu không có thuốc hoặc tồn kho nhỏ hơn số lượng: `ROLLBACK`, gán thông báo lỗi, thoát thủ tục.
5. Thao tác 'Kho': trừ `stock`.
6. Thao tác 'Công nợ': cộng `số lượng × đơn giá` vào `total_due`.
7. `COMMIT`, gán `"Đã cấp phát thành công"`.
8. Lỗi hệ thống bất ngờ ở bất kỳ bước nào: `EXIT HANDLER` chạy `ROLLBACK` và trả thông báo lỗi.

## 3. Triển khai

```sql
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
```

- **Nhãn `proc:` và `LEAVE proc`:** thoát thủ tục ngay sau khi `ROLLBACK`, không chạy tiếp các thao tác cập nhật.
- **`INSERT ... ON DUPLICATE KEY UPDATE`:** bệnh nhân đã có dòng công nợ thì cộng dồn; chưa có thì tạo mới. Nhờ vậy thao tác 'Công nợ' không bị bỏ sót, trong khi lệnh `UPDATE` thường sẽ cập nhật 0 dòng mà không báo lỗi.
- **Trả thông báo bằng `OUT` thay vì `SIGNAL`:** màn hình luôn nhận được một chuỗi trạng thái để hiển thị, kể cả khi thất bại.

## 4. Kiểm thử

```sql
-- Trường hợp 1: cấp phát hợp lệ
CALL DispenseMedicine(1, 1, 10, @msg);
SELECT @msg AS message;

-- Trường hợp 2: vượt tồn kho
CALL DispenseMedicine(2, 2, 10, @msg);
SELECT @msg AS message;
```

| Trường hợp | Dữ liệu | @msg | Thay đổi dữ liệu |
|---|---|---|---|
| 1. Hợp lệ | BN 1, Paracetamol (tồn 100), số lượng 10 | `Đã cấp phát thành công` | Tồn kho 100 → **90**; công nợ BN 1: 0 → **50.000** |
| 2. Vượt tồn kho | BN 2, Amoxicillin (tồn 5), số lượng 10 | `Lỗi: Số lượng tồn kho không đủ` | Không đổi: tồn kho vẫn 5, công nợ BN 2 vẫn 50.000 |

Dữ liệu sau 2 lần gọi:

| medicine_id | medicine_name | stock |
|---|---|---|
| 1 | Paracetamol 500mg | 90 |
| 2 | Amoxicillin 250mg | 5 |
| 3 | Vitamin C 1000mg | 200 |

| patient_id | total_due |
|---|---|
| 1 | 50000.00 |
| 2 | 50000.00 |
