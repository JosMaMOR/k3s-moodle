<?php
// ============================================================
// configure-cache.php — K3s TESOEM
// Siembra IDEMPOTENTE del store Redis en la MUC de Moodle.
// La invoca entrypoint.sh (paso 7b) en cada arranque, 5a y 5b.
//
// Moodle NO configura el caché de aplicación desde config.php:
// vive en moodledata/muc/config.php. Este script lo escribe con
// la API oficial (config_writer), que respeta el siteidentifier
// y la estructura de modos/features de la versión instalada.
//
// Resultado:
//   store  '<MOODLE_CACHE_STORE>' (plugin redis) → REDIS_HOST:PORT
//   Application → Redis · Session → Redis · Request → default
// ============================================================

define('CLI_SCRIPT', true);
require(getenv('MOODLE_CONFIG') ?: '/var/www/html/config.php');

$storename = getenv('MOODLE_CACHE_STORE')  ?: 'redis-k3s';
$host      = getenv('REDIS_HOST')          ?: 'redis';
$port      = (int) (getenv('REDIS_PORT')   ?: 6379);
$password  = (string) getenv('REDIS_PASSWORD');
$prefix    = getenv('MOODLE_CACHE_PREFIX') ?: 'mdlc_';

// Valores de modo de la MUC (estables desde Moodle 2.4).
const K3S_MODE_APPLICATION = 1;
const K3S_MODE_SESSION     = 2;
const K3S_MODE_REQUEST     = 4;

function k3s_fail(string $msg): void {
    fwrite(STDERR, "ERROR: {$msg}\n");
    exit(1);
}

// 1. Requisitos: extensión phpredis y Redis accesible con el password.
if (!class_exists('Redis')) {
    k3s_fail('extensión phpredis no cargada');
}
try {
    $r = new Redis();
    if (!$r->connect($host, $port, 3.0)) {
        k3s_fail("no conecta a {$host}:{$port}");
    }
    if ($password !== '' && !$r->auth($password)) {
        k3s_fail('AUTH rechazado — revisar REDIS_PASSWORD');
    }
    $r->ping();
    $r->close();
} catch (Throwable $e) {
    k3s_fail('Redis: ' . $e->getMessage());
}
echo "Redis OK en {$host}:{$port}\n";

// 2. Writer de la MUC (Moodle 5.x: \core_cache\config_writer;
//    el nombre legacy queda como fallback).
$writerclass = class_exists('\core_cache\config_writer')
    ? '\core_cache\config_writer'
    : 'cache_config_writer';
$writer = $writerclass::instance();

$storeconfig = [
    'server'     => "{$host}:{$port}",
    'prefix'     => $prefix,
    'password'   => $password,
    'serializer' => 1, // Redis::SERIALIZER_PHP
    'compressor' => 0, // sin compresión
];

// 3. Store: crear si falta; actualizar si la config cambió (p.ej. password).
$stores = $writer->get_all_stores();
if (!array_key_exists($storename, $stores)) {
    $writer->add_store_instance($storename, 'redis', $storeconfig);
    echo "store '{$storename}' creado\n";
} else if (($stores[$storename]['configuration'] ?? []) != $storeconfig) {
    $writer->edit_store_instance($storename, 'redis', $storeconfig);
    echo "store '{$storename}' actualizado\n";
} else {
    echo "store '{$storename}' sin cambios\n";
}

// 4. Mappings de modo: solo se escriben si difieren.
$desired = [
    K3S_MODE_APPLICATION => [$storename],
    K3S_MODE_SESSION     => [$storename],
    K3S_MODE_REQUEST     => ['default_request'],
];
$current = [K3S_MODE_APPLICATION => [], K3S_MODE_SESSION => [], K3S_MODE_REQUEST => []];
foreach ($writer->get_mode_mappings() as $m) {
    $current[(int) $m['mode']][] = $m['store'];
}
if ($current != $desired) {
    $writer->set_mode_mappings($desired);
    echo "mappings: application+session → '{$storename}', request → default\n";
} else {
    echo "mappings sin cambios\n";
}
exit(0);
