# Tự động hóa giao dịch thiết bị y tế

Xây dựng thủ tục `ProcessEquipmentPurchase` đồng bộ việc trừ kho thiết bị và trừ tiền ví trả trước trong cùng một giao dịch, với 3 ràng buộc Out of stock, Insufficient funds và Locked Account.

## 1. Đề bài

- **Bối cảnh:** quy trình mua thiết bị y tế bằng ví trả trước hiện không đồng bộ: trừ tồn kho trước, sau đó mới trừ tiền. Nếu bước trừ tiền lỗi kết nối, dữ liệu tồn kho vẫn bị trừ, gây sai lệch cơ sở dữ liệu. Backend sẽ truyền vào: Mã bệnh nhân, Mã sản phẩm và Số lượng.
- **Quy tắc nghiệp vụ:** trong cùng một khối giao dịch:
  - trừ số lượng mua trong bảng thiết bị (`Products`);
  - tính Thành tiền = Số lượng × Đơn giá;
  - trừ Thành tiền vào số dư ví (`Wallets`);
  - không có lỗi thì lưu thay đổi và trả về `"Thành công: Đã xử lý đơn hàng"`.
- **Ràng buộc:** kiểm tra và hoàn tác toàn bộ nếu vi phạm:
  - **Out of stock:** số lượng mua lớn hơn tồn kho, báo `"Thất bại: Kho không đủ sản phẩm"`.
  - **Insufficient funds:** thành tiền lớn hơn số dư ví, báo `"Thất bại: Số dư ví không đủ"`.
  - **Locked Account:** ví ở trạng thái `'Inactive'`, báo `"Thất bại: Ví đang bị khóa"`.

Đề bài nói bảng `Products` và `Wallets` đã có trong `RikkeiClinicDB`, nhưng script đó không chứa 2 bảng này, nên file `giao_dich_thiet_bi.sql` tự tạo:

```sql
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
    status     VARCHAR(20)    NOT NULL DEFAULT 'Active'
) ENGINE = InnoDB;

INSERT INTO Products (product_id, product_name, price, stock_quantity) VALUES
    (1, 'May do huyet ap',    850000,  10),
    (2, 'Nhiet ke dien tu',   120000,   2),
    (3, 'May do duong huyet', 1500000,  5);

INSERT INTO Wallets (wallet_id, patient_id, balance, status) VALUES
    (1, 1, 3000000, 'Active'),
    (2, 2,  200000, 'Active'),
    (3, 3, 5000000, 'Inactive');
```

## 2. Phần A – Phân tích và thiết kế

### Phân tích I/O

| Tham số | Loại | Kiểu | Ý nghĩa |
|---|---|---|---|
| `p_patient_id` | `IN` | INT | Mã bệnh nhân |
| `p_product_id` | `IN` | INT | Mã sản phẩm |
| `p_quantity` | `IN` | INT | Số lượng mua |
| `p_message` | `OUT` | VARCHAR(255) | Chuỗi "Thông báo trạng thái" trả về Backend |

Chuỗi thông báo cần tham số **`OUT`**: giá trị do thủ tục tạo ra và trả về cho Backend sau khi chạy xong; Backend không cần truyền giá trị nào vào. `INOUT` chỉ cần khi một giá trị vừa được truyền vào vừa bị thủ tục sửa rồi trả lại, nên không phù hợp ở đây.

### Biến cục bộ

| Biến | Kiểu | Hứng dữ liệu |
|---|---|---|
| `v_stock` | INT | Tồn kho hiện tại của sản phẩm |
| `v_price` | DECIMAL(15,2) | Đơn giá sản phẩm |
| `v_total` | DECIMAL(15,2) | Thành tiền = `p_quantity * v_price` |
| `v_balance` | DECIMAL(15,2) | Số dư ví |
| `v_wallet_status` | VARCHAR(20) | Trạng thái ví |

### Luồng xử lý và vị trí các lệnh kiểm soát giao dịch

1. Kiểm tra `p_quantity > 0`; sai thì trả thông báo lỗi và thoát (chưa mở giao dịch).
2. **`START TRANSACTION`**.
3. `SELECT stock_quantity, price ... FOR UPDATE`: đọc và khóa dòng sản phẩm.
4. Sản phẩm không tồn tại, hoặc `v_stock < p_quantity` (**Out of stock**): **`ROLLBACK`**, thoát.
5. Tính `v_total = p_quantity * v_price`.
6. `SELECT balance, status ... FOR UPDATE`: đọc và khóa dòng ví.
7. Không có ví, hoặc ví `'Inactive'` (**Locked Account**): **`ROLLBACK`**, thoát.
8. `v_balance < v_total` (**Insufficient funds**): **`ROLLBACK`**, thoát.
9. `UPDATE Products` (trừ kho), rồi `UPDATE Wallets` (trừ tiền).
10. **`COMMIT`**, trả `"Thành công: Đã xử lý đơn hàng"`.
11. Lỗi hệ thống bất ngờ ở bất kỳ bước nào: `EXIT HANDLER` chạy **`ROLLBACK`**.

Tất cả kiểm tra được thực hiện **trước** khi ghi dữ liệu. Nhờ vậy hai lệnh `UPDATE` chỉ chạy khi chắc chắn hợp lệ, và nếu lệnh trừ tiền lỗi kết nối thì `EXIT HANDLER` hoàn tác cả lệnh trừ kho trước đó. Ví bị khóa được kiểm tra trước số dư, để ví vừa bị khóa vừa thiếu tiền báo đúng lý do gốc là "đang bị khóa".

## 3. Phần B – Triển khai code

```sql
DROP PROCEDURE IF EXISTS ProcessEquipmentPurchase;

DELIMITER //

CREATE PROCEDURE ProcessEquipmentPurchase(
    IN  p_patient_id INT,
    IN  p_product_id INT,
    IN  p_quantity   INT,
    OUT p_message    VARCHAR(255)
)
proc: BEGIN
    DECLARE v_stock         INT            DEFAULT NULL;
    DECLARE v_price         DECIMAL(15, 2) DEFAULT NULL;
    DECLARE v_total         DECIMAL(15, 2) DEFAULT 0;
    DECLARE v_balance       DECIMAL(15, 2) DEFAULT NULL;
    DECLARE v_wallet_status VARCHAR(20)    DEFAULT NULL;

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

    SELECT stock_quantity, price INTO v_stock, v_price
    FROM Products
    WHERE product_id = p_product_id
    FOR UPDATE;

    IF v_stock IS NULL THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Sản phẩm không tồn tại';
        LEAVE proc;
    END IF;

    IF v_stock < p_quantity THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Kho không đủ sản phẩm';
        LEAVE proc;
    END IF;

    SET v_total = p_quantity * v_price;

    SELECT balance, status INTO v_balance, v_wallet_status
    FROM Wallets
    WHERE patient_id = p_patient_id
    FOR UPDATE;

    IF v_wallet_status IS NULL THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Bệnh nhân chưa có ví';
        LEAVE proc;
    END IF;

    IF v_wallet_status = 'Inactive' THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Ví đang bị khóa';
        LEAVE proc;
    END IF;

    IF v_balance < v_total THEN
        ROLLBACK;
        SET p_message = 'Thất bại: Số dư ví không đủ';
        LEAVE proc;
    END IF;

    UPDATE Products
    SET stock_quantity = stock_quantity - p_quantity
    WHERE product_id = p_product_id;

    UPDATE Wallets
    SET balance = balance - v_total
    WHERE patient_id = p_patient_id;

    COMMIT;
    SET p_message = 'Thành công: Đã xử lý đơn hàng';
END //

DELIMITER ;
```

## 4. Kiểm thử

```sql
CALL ProcessEquipmentPurchase(1, 1, 2, @msg); SELECT @msg;  -- (1) hợp lệ
CALL ProcessEquipmentPurchase(1, 2, 5, @msg); SELECT @msg;  -- (2) Out of stock
CALL ProcessEquipmentPurchase(2, 3, 1, @msg); SELECT @msg;  -- (3) Insufficient funds
CALL ProcessEquipmentPurchase(3, 1, 1, @msg); SELECT @msg;  -- (4) Locked Account
```

| Kịch bản | Dữ liệu | @msg |
|---|---|---|
| 1. Mua hợp lệ | BN 1 (ví 3.000.000) mua 2 máy đo huyết áp × 850.000 | `Thành công: Đã xử lý đơn hàng` |
| 2. Out of stock | BN 1 mua 5 nhiệt kế (kho còn 2) | `Thất bại: Kho không đủ sản phẩm` |
| 3. Insufficient funds | BN 2 (ví 200.000) mua 1 máy đo đường huyết 1.500.000 | `Thất bại: Số dư ví không đủ` |
| 4. Locked Account | BN 3 (ví `Inactive`, 5.000.000) mua 1 máy đo huyết áp | `Thất bại: Ví đang bị khóa` |

Dữ liệu sau 4 lần gọi (chỉ kịch bản 1 làm thay đổi dữ liệu):

| product_id | product_name | stock_quantity |
|---|---|---|
| 1 | May do huyet ap | 8 |
| 2 | Nhiet ke dien tu | 2 |
| 3 | May do duong huyet | 5 |

| patient_id | balance | status |
|---|---|---|
| 1 | 1300000.00 | Active |
| 2 | 200000.00 | Active |
| 3 | 5000000.00 | Inactive |
