package org.lgtm.examples;

import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * d: the only role with a database. Every fifth query or so is slow on purpose (pg_sleep), so PostgreSQL logs
 * it (log_min_duration_statement = 1s, examples/postgres/postgresql.conf).
 * The statement starts with the business id as SQL comment; the OTel agent appends the trace context
 * (sqlcommenter: traceparent='00-<trace id>-<span id>-01'). Both end up in the slow query log, from where
 * Alloy (examples/postgres/alloy.alloy) extracts trace_id, span_id and order.id.
 */
@RestController
@Profile("catalog")
class CatalogController {
    private static final Logger log = LoggerFactory.getLogger(CatalogController.class);
    private static final String QUERY = """
            SELECT id, name, stock, price
            FROM items, LATERAL (SELECT pg_sleep(CASE WHEN random() < 0.2 THEN 1.2 ELSE 0.01 END)) AS slow
            WHERE id = ?""";
    private final JdbcTemplate jdbc;

    CatalogController(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @GetMapping("/items/{id}")
    Map<String, Object> item(@PathVariable int id) {
        String orderId = OrderId.current();   // validated by OrderId's filter: [A-Za-z0-9-] only
        String sql = (orderId != null ? "/* order.id='" + orderId + "' */ " : "") + QUERY;
        Map<String, Object> item = jdbc.queryForMap(sql, id);
        log.info("item {} loaded", id);
        return item;
    }
}
