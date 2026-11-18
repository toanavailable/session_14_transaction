# Thực thi và kiểm soát giao dịch trong MySQL

Bài thực hành kiểm chứng lệnh `ROLLBACK` và xây dựng thủ tục chuyển tiền an toàn `sp_transfer_money` trên bảng `account`.

## 1. Đề bài

- **Mục tiêu:**
  - thành thạo các lệnh điều khiển giao dịch `START TRANSACTION`, `COMMIT`, `ROLLBACK`;
  - hiểu cơ chế `autocommit` và cách kiểm soát nó trong phiên làm việc;
  - vận dụng Transaction trong Stored Procedure cho nghiệp vụ chuyển tiền.
- **Bước 1:** mở giao dịch, chèn 2 tài khoản `'Lê Văn C'` (số dư 500) và `'Trần Thị D'` (số dư 300), `SELECT` xác nhận dữ liệu tạm thời, `ROLLBACK`, kiểm tra lại thấy 2 tài khoản đã biến mất.
- **Bước 2:** tạo thủ tục `sp_transfer_money(sender_id, receiver_id, amount)`. Logic: `START TRANSACTION` → cộng tiền người nhận → trừ tiền người gửi → `SELECT INTO v_balance` lấy số dư mới nhất của người gửi.
- **Bước 3:** nếu `v_balance < 50` thì `ROLLBACK` và báo lỗi `"Giao dịch thất bại: Số dư tối thiểu phải còn 50!"`, ngược lại `COMMIT`.
- **Bước 4:** gọi thủ tục với TH1 (thành công) và TH2 (số dư người gửi còn dưới 50).

## 2. Chuẩn bị dữ liệu

```sql
CREATE DATABASE IF NOT EXISTS bank_practice CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE bank_practice;

CREATE TABLE account (
    id      INT AUTO_INCREMENT PRIMARY KEY,
    name    VARCHAR(100)   NOT NULL,
    balance DECIMAL(15, 2) NOT NULL DEFAULT 0
) ENGINE = InnoDB;

INSERT INTO account (name, balance) VALUES
    ('Nguyễn Văn A', 1000),
    ('Trần Thị B',    200);
```

Bảng phải dùng engine **InnoDB**, vì MyISAM không hỗ trợ giao dịch: `ROLLBACK` trên MyISAM không hoàn tác được gì.

## 3. Cơ chế autocommit

```sql
SELECT @@autocommit;   -- 1: mặc định bật
```

Khi `autocommit = 1`, mỗi lệnh `INSERT`, `UPDATE`, `DELETE` tự thành một giao dịch và được `COMMIT` ngay khi chạy xong, nên không thể `ROLLBACK` được nữa. Có 2 cách để gom nhiều lệnh thành một giao dịch:

- **`START TRANSACTION`:** tạm dừng autocommit cho tới khi gặp `COMMIT` hoặc `ROLLBACK`, sau đó tự bật lại. Đây là cách dùng trong bài.
- **`SET autocommit = 0`:** tắt autocommit cho cả phiên làm việc; mọi lệnh sau đó đều phải tự `COMMIT`, cho tới khi `SET autocommit = 1`.

## 4. Bước 1 – Kiểm chứng lệnh ROLLBACK

```sql
START TRANSACTION;

INSERT INTO account (name, balance) VALUES
    ('Lê Văn C',   500),
    ('Trần Thị D', 300);

SELECT * FROM account;   -- thấy 4 tài khoản

ROLLBACK;

SELECT * FROM account;   -- chỉ còn 2 tài khoản
```

| Thời điểm | Kết quả `SELECT * FROM account` |
|---|---|
| Trước `ROLLBACK` | 4 dòng: Nguyễn Văn A, Trần Thị B, **Lê Văn C, Trần Thị D** |
| Sau `ROLLBACK` | 2 dòng: Nguyễn Văn A (1000), Trần Thị B (200) |

Hai tài khoản mới chỉ tồn tại tạm thời trong giao dịch đang mở; `ROLLBACK` hủy toàn bộ thay đổi chưa `COMMIT`. Riêng bộ đếm `AUTO_INCREMENT` không bị hoàn lại, nên tài khoản thêm sau này sẽ có `id` là 5.

## 5. Bước 2 và 3 – Thủ tục chuyển tiền sp_transfer_money

```sql
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
```

- **`START TRANSACTION`:** tạm dừng autocommit, nên 2 lệnh `UPDATE` chỉ là thay đổi tạm cho tới khi có quyết định cuối cùng.
- **`SELECT balance INTO v_balance`:** đọc số dư **sau khi** đã trừ tiền, để kiểm tra người gửi còn đủ mức tối thiểu 50 không.
- **`ROLLBACK` rồi mới `SIGNAL`:** hoàn tác cả lệnh cộng tiền cho người nhận lẫn lệnh trừ tiền người gửi, sau đó mới ném lỗi để ứng dụng biết giao dịch thất bại.
- **`EXIT HANDLER` (bổ sung):** bảo đảm cả những lỗi không lường trước cũng được `ROLLBACK`, không để giao dịch treo ở trạng thái dở dang.

## 6. Bước 4 – Thực thi kiểm tra

```sql
-- TH1: thành công
CALL sp_transfer_money(1, 2, 300);
SELECT * FROM account;

-- TH2: thất bại
CALL sp_transfer_money(1, 2, 680);
SELECT * FROM account;
```

| Trường hợp | Giao dịch | Kết quả CALL | Số dư A | Số dư B |
|---|---|---|---|---|
| Ban đầu | | | 1000 | 200 |
| TH1 | A chuyển 300 cho B (A còn 700) | Thành công, `COMMIT` | **700** | **500** |
| TH2 | A chuyển 680 cho B (A sẽ còn 20 < 50) | `Error Code: 1644. Giao dịch thất bại: Số dư tối thiểu phải còn 50!` | 700 | 500 |

Ở TH2, lệnh cộng 680 cho B đã chạy trước, nhưng `ROLLBACK` đưa cả hai tài khoản về đúng trạng thái trước khi gọi thủ tục. TH2 báo lỗi nên được đặt cuối file `.sql`; để chạy cả lệnh `SELECT` sau nó trong MySQL Workbench, tắt **Query → Stop Script Execution on Errors**.
