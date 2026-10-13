<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/db_connect.php';

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
header('X-Content-Type-Options: nosniff');
header('X-Frame-Options: DENY');
header("Content-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");

if (getenv('AUTH_REQUIRED') === 'true') {
    $principalHeader = $_SERVER['HTTP_X_MS_CLIENT_PRINCIPAL'] ?? '';
    $principalJson = base64_decode($principalHeader, true);
    $principal = is_string($principalJson) ? json_decode($principalJson, true) : null;
    $user = is_array($principal) && isset($principal['userDetails']) && is_string($principal['userDetails'])
        ? strtolower(trim($principal['userDetails']))
        : '';
    if ($user === '' || !in_array($user, allowedUsers(), true)) {
        http_response_code(403);
        exit('Access denied.');
    }
}

session_start([
    'use_strict_mode' => true,
    'cookie_httponly' => true,
    'cookie_samesite' => 'Strict',
    'cookie_secure' => getenv('SESSION_COOKIE_SECURE') === 'true'
        || (isset($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off'),
]);

if (!isset($_SESSION['csrf_token'])) {
    $_SESSION['csrf_token'] = bin2hex(random_bytes(32));
}

function escapeHtml(string $value): string
{
    return htmlspecialchars($value, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
}

$items = [];
$error = null;
$success = isset($_GET['updated']) && $_GET['updated'] === '1';

try {
    $database = connectDatabase();
    if ($_SERVER['REQUEST_METHOD'] === 'POST') {
        $token = $_POST['csrf_token'] ?? null;
        if (!is_string($token) || !hash_equals($_SESSION['csrf_token'], $token)) {
            http_response_code(403);
            $error = 'Invalid request token. Reload the page and try again.';
        } else {
            $id = filter_var($_POST['id'] ?? null, FILTER_VALIDATE_INT, ['options' => ['min_range' => 1]]);
            $quantity = filter_var($_POST['quantity'] ?? null, FILTER_VALIDATE_INT, [
                'options' => ['min_range' => 0, 'max_range' => 1000000],
            ]);
            if ($id === false || $quantity === false) {
                http_response_code(422);
                $error = 'Select an existing item and a whole-number quantity between 0 and 1000000.';
            } else {
                $statement = $database->prepare(
                    'UPDATE inventory SET quantity = :quantity, updated_at = CURRENT_TIMESTAMP WHERE id = :id'
                );
                $statement->execute(['quantity' => $quantity, 'id' => $id]);
                if ($statement->rowCount() !== 1) {
                    http_response_code(404);
                    $error = 'The inventory item no longer exists.';
                } else {
                    header('Location: index.php?updated=1', true, 303);
                    exit;
                }
            }
        }
    }
    $items = $database->query(
        'SELECT id, sku, name, category, quantity, unit, updated_at FROM inventory ORDER BY name'
    )->fetchAll();
} catch (PDOException $exception) {
    error_log('Inventory database failure; SQLSTATE: ' . $exception->getCode());
    http_response_code(503);
    $error = 'Inventory is unavailable. Check database connectivity and initialization; see server logs.';
} catch (RuntimeException $exception) {
    error_log('Inventory configuration failure: ' . $exception->getMessage());
    http_response_code(503);
    $error = 'Inventory configuration is incomplete or invalid. See server logs for the required setting.';
}
?>
<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Food Inventory Database - Derniere Recolte</title>
    <style>
        body { font-family: system-ui, sans-serif; max-width: 1100px; margin: 2rem auto; padding: 0 1rem; color: #243029; background: #faf8f2; }
        table { width: 100%; border-collapse: collapse; background: white; }
        th, td { padding: .75rem; text-align: left; border-bottom: 1px solid #ddd; }
        input { width: 7rem; padding: .4rem; }
        button { padding: .45rem .75rem; cursor: pointer; }
        .error { padding: 1rem; background: #ffe2e2; }
        .success { padding: 1rem; background: #e0f1e5; }
        .table-container { overflow-x: auto; }
    </style>
</head>
<body>
    <h1>Food Inventory Database</h1>
    <p>Derniere Recolte - synthetic hackathon stocktake</p>
    <p>This local demonstration has no user authentication. Do not expose it publicly.</p>
    <?php if ($error !== null): ?>
        <p class="error" role="alert"><?= escapeHtml($error) ?></p>
    <?php endif; ?>
    <?php if ($success && $error === null): ?>
        <p class="success" role="status">Stock quantity updated.</p>
    <?php endif; ?>
    <div class="table-container">
        <table>
            <thead><tr><th>SKU</th><th>Product</th><th>Category</th><th>Stock</th><th>Updated</th><th>Stocktake</th></tr></thead>
            <tbody>
                <?php foreach ($items as $item): ?>
                    <tr>
                        <td><?= escapeHtml($item['sku']) ?></td>
                        <td><?= escapeHtml($item['name']) ?></td>
                        <td><?= escapeHtml($item['category']) ?></td>
                        <td><?= escapeHtml((string) $item['quantity']) ?> <?= escapeHtml($item['unit']) ?></td>
                        <td><?= escapeHtml($item['updated_at']) ?></td>
                        <td>
                            <form method="post" action="index.php">
                                <input type="hidden" name="csrf_token" value="<?= escapeHtml($_SESSION['csrf_token']) ?>">
                                <input type="hidden" name="id" value="<?= escapeHtml((string) $item['id']) ?>">
                                <label>
                                    <span>Quantity for <?= escapeHtml($item['name']) ?></span>
                                    <input type="number" name="quantity" min="0" max="1000000" required value="<?= escapeHtml((string) $item['quantity']) ?>">
                                </label>
                                <button type="submit">Save</button>
                            </form>
                        </td>
                    </tr>
                <?php endforeach; ?>
                <?php if ($items === [] && $error === null): ?>
                    <tr><td colspan="6">No inventory items. Load the synthetic initialization script.</td></tr>
                <?php endif; ?>
            </tbody>
        </table>
    </div>
</body>
</html>
