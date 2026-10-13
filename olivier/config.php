<?php
declare(strict_types=1);

function requiredEnvironmentVariable(string $name): string
{
    $value = getenv($name);
    if ($value === false || trim($value) === '') {
        throw new RuntimeException('Missing required environment variable: ' . $name);
    }
    return $value;
}

function databaseConfig(): array
{
    $port = getenv('DB_PORT');
    $port = ($port === false || $port === '') ? '5432' : $port;
    if (!ctype_digit($port) || (int) $port < 1 || (int) $port > 65535) {
        throw new RuntimeException('DB_PORT must be an integer between 1 and 65535.');
    }

    $sslMode = getenv('DB_SSLMODE');
    $sslMode = ($sslMode === false || $sslMode === '') ? 'require' : $sslMode;
    if (!in_array($sslMode, ['disable', 'require', 'verify-ca', 'verify-full'], true)) {
        throw new RuntimeException('DB_SSLMODE must be disable, require, verify-ca, or verify-full.');
    }

    $host = requiredEnvironmentVariable('DB_HOST');
    $name = requiredEnvironmentVariable('DB_NAME');
    foreach ([$host, $name] as $dsnValue) {
        if (preg_match('/[;\s]/', $dsnValue)) {
            throw new RuntimeException('DB_HOST and DB_NAME must not contain whitespace or semicolons.');
        }
    }

    return [
        'dsn' => sprintf('pgsql:host=%s;port=%s;dbname=%s;sslmode=%s', $host, $port, $name, $sslMode),
        'user' => requiredEnvironmentVariable('DB_USER'),
        'password' => requiredEnvironmentVariable('DB_PASSWORD'),
    ];
}

function allowedUsers(): array
{
    return array_values(array_filter(array_map(
        static fn(string $email): string => strtolower(trim($email)),
        explode(',', getenv('ALLOWED_USERS') ?: '')
    )));
}
