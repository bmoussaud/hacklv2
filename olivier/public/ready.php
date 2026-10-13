<?php
declare(strict_types=1);

require_once dirname(__DIR__) . '/db_connect.php';
header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

try {
    connectDatabase()->query('SELECT 1');
    http_response_code(200);
    echo "ready\n";
} catch (PDOException $exception) {
    error_log('Inventory readiness check failed; SQLSTATE: ' . $exception->getCode());
    http_response_code(503);
    echo "unavailable\n";
} catch (RuntimeException $exception) {
    error_log('Inventory readiness configuration failure: ' . $exception->getMessage());
    http_response_code(503);
    echo "unavailable\n";
}
