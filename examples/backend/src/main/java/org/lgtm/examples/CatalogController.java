package org.lgtm.examples;

import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.Map;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.context.annotation.Profile;
import org.springframework.jdbc.core.ConnectionCallback;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RestController;

/**
 * d: the only role with a database. Every fifth query or so is slow on purpose (pg_sleep), so PostgreSQL logs
 * it (log_min_duration_statement = 1s, examples/postgres/postgresql.conf). The log line can be correlated:
 * <ul>
 *   <li>trace: the OTel agent appends the trace context as SQL comment (sqlcommenter,
 *       {@code /*traceparent='00-<trace id>-<span id>-01'*}{@code /}). sqlcommenter leaves statements that
 *       already contain a comment alone, so the statement itself has none.</li>
 *   <li>business id: the session's application_name is "catalog order.id=<id>" while the query runs (JDBC
 *       client info, sent safely by the driver). PostgreSQL writes it into every log line, and it is visible
 *       live in pg_stat_activity.</li>
 * </ul>
 * Alloy (examples/postgres/alloy.alloy) turns both into the log's trace_id/span_id and order.id.
 */
@RestController
@Profile("catalog")
class CatalogController {
    private static final Logger log = LoggerFactory.getLogger(CatalogController.class);
    private static final String APPLICATION = "catalog";
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
        String orderId = OrderId.current();
        Map<String, Object> item = jdbc.execute((ConnectionCallback<Map<String, Object>>) connection -> {
            connection.setClientInfo("ApplicationName",
                    orderId != null ? APPLICATION + " " + OrderId.KEY + "=" + orderId : APPLICATION);
            try (PreparedStatement statement = connection.prepareStatement(QUERY)) {
                statement.setInt(1, id);
                try (ResultSet row = statement.executeQuery()) {
                    row.next();
                    return Map.of("id", row.getInt("id"), "name", row.getString("name"),
                            "stock", row.getInt("stock"), "price", row.getBigDecimal("price"));
                }
            } finally {
                connection.setClientInfo("ApplicationName", APPLICATION);   // pooled connection: reset the tag
            }
        });
        log.info("item {} loaded", id);
        return item;
    }
}
