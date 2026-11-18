# Sự cố giao dịch chưa hoàn tất

Phân tích lỗi "tiền đã trừ nhưng nợ không giảm" của thủ tục `PayHospitalFee`, và viết lại thủ tục với `START TRANSACTION`, `COMMIT`, `ROLLBACK` để hai bước thanh toán luôn thành công hoặc thất bại cùng nhau.

## 1. Đề bài

- **Nghiệp vụ:** bệnh nhân dùng "Ví trả trước" để thanh toán viện phí.
- **Quy tắc hệ thống:** trừ tiền trong ví và giảm trừ công nợ phải là một khối giao dịch thống nhất: hoặc cùng thành công, hoặc hủy toàn bộ nếu có lỗi.
- **Sự cố:** máy chủ mới trừ tiền trong ví nhưng chưa kịp giảm công nợ thì gặp sự cố mạng; bệnh nhân bị mất tiền oan và sổ sách sai lệch.
- **Mã nguồn hiện tại:**

```sql
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
```

Script `RikkeiClinicDB` không có 2 bảng `Wallets` và `Patient_Invoices`, nên file `giao_dich_chua_hoan_tat.sql` tự tạo:

```sql
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
```

File `.sql` có các lệnh `CALL` cố ý gây lỗi. Để chạy hết file trong MySQL Workbench, tắt **Query → Stop Script Execution on Errors** (hoặc chạy `mysql --force`).

## 2. Phần A – Phân tích

### Tái hiện lỗi

```sql
CALL PayHospitalFee(1, 500000);

SELECT w.patient_id, w.balance, i.total_due
FROM Wallets AS w
INNER JOIN Patient_Invoices AS i ON i.patient_id = w.patient_id
WHERE w.patient_id = 1;
```

Lệnh `CALL` báo `Error Code: 1644. Lỗi: Hệ thống gặp sự cố mạng đột ngột!`, nhưng dữ liệu đã bị thay đổi một nửa:

| patient_id | balance trước | balance sau | total_due trước | total_due sau |
|---|---|---|---|---|
| 1 | 1.000.000 | **500.000** | 500.000 | **500.000** |

### Vi phạm tính chất nào của ACID?

Sự cố vi phạm tính **Atomicity (Nguyên tử)**: hai bước thanh toán phải là một khối "tất cả hoặc không gì cả", nhưng thủ tục cũ không mở transaction. Ở chế độ mặc định `autocommit = 1`, lệnh `UPDATE Wallets` được lưu vĩnh viễn ngay khi chạy xong, nên khi lỗi xảy ra không còn gì để hoàn tác. Hệ quả là dữ liệu mất cả tính **Consistency (Nhất quán)**: tiền đã trừ trong ví không khớp với công nợ còn lại.

## 3. Phần B – Sửa chữa mã nguồn

```sql
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
```

- **`START TRANSACTION`:** tạm dừng `autocommit`; các lệnh `UPDATE` chỉ được ghi tạm cho tới khi gặp `COMMIT`.
- **`DECLARE EXIT HANDLER FOR SQLEXCEPTION`:** lỗi ở bất kỳ bước nào (kể cả lỗi do `SIGNAL`) đều nhảy vào handler. Handler chạy `ROLLBACK` để hoàn tác lệnh trừ tiền, rồi `RESIGNAL` để ném lỗi gốc ra cho ứng dụng biết giao dịch thất bại.
- **`COMMIT` đặt cuối cùng:** chỉ khi cả 2 bước chạy xong thì dữ liệu mới được lưu vĩnh viễn.
- **Giả lập sự cố bằng `@simulate_network_error`:** đề bài giả lập sự cố bằng `SIGNAL` luôn chạy, nên thủ tục không bao giờ thành công. Bản sửa chỉ ném lỗi khi bật biến phiên này, nhờ đó kiểm thử được cả trường hợp lỗi lẫn trường hợp thành công. Khi đưa lên hệ thống thật, xóa khối `IF` này đi.
- **Kiểm tra thêm (ngoài đề bài):** ví không tồn tại, số tiền ≤ 0, số dư không đủ. `SELECT ... FOR UPDATE` khóa dòng ví để hai lần thanh toán cùng lúc không cùng đọc một số dư cũ.

## 4. Kiểm thử

```sql
-- Test 1: sự cố xảy ra giữa 2 bước
SET @simulate_network_error = 1;
CALL PayHospitalFee(1, 500000);

-- Test 2: hệ thống bình thường
SET @simulate_network_error = 0;
CALL PayHospitalFee(1, 500000);
```

| Test | Kết quả CALL | balance | total_due |
|---|---|---|---|
| Ban đầu | | 1.000.000 | 500.000 |
| 1. Có sự cố giữa chừng | `Error Code: 1644. Lỗi: Hệ thống gặp sự cố mạng đột ngột!` | **1.000.000** (được hoàn lại) | 500.000 |
| 2. Bình thường | Thành công | 500.000 | 0 |

Ở Test 1, lệnh trừ tiền đã chạy nhưng bị `ROLLBACK` hoàn tác, nên ví không mất tiền oan như với thủ tục cũ.
