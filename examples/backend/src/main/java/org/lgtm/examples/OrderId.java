package org.lgtm.examples;

import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.api.trace.Span;
import io.opentelemetry.context.Scope;
import jakarta.servlet.FilterChain;
import jakarta.servlet.ServletException;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.util.regex.Pattern;
import org.slf4j.MDC;
import org.springframework.boot.restclient.RestClientCustomizer;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.web.filter.OncePerRequestFilter;

/**
 * The business id "order.id", followed through every service (custom code; the agent only carries the trace).
 * <ul>
 *   <li>in: header X-Order-Id (set by the frontend), else W3C baggage "order.id"</li>
 *   <li>span attribute order.id on the server span -> Tempo: {span.order.id="..."}</li>
 *   <li>MDC order.id -> every log line; the agent exports it as log attribute -> Loki: | order_id="..."</li>
 *   <li>out: header X-Order-Id + baggage on every RestClient call (the header also works without the agent)</li>
 *   <li>catalog: session application_name "catalog order.id=..." -> PostgreSQL's log (CatalogController)</li>
 * </ul>
 */
@Configuration
public class OrderId {
    public static final String HEADER = "X-Order-Id";
    public static final String KEY = "order.id";
    // only ids that are safe in a header, a log line and an application_name
    private static final Pattern VALID = Pattern.compile("[A-Za-z0-9-]{1,64}");

    public static String current() {
        return MDC.get(KEY);
    }

    @Bean
    OncePerRequestFilter orderIdFilter() {
        return new OncePerRequestFilter() {
            @Override
            protected void doFilterInternal(HttpServletRequest request, HttpServletResponse response, FilterChain chain)
                    throws ServletException, IOException {
                String id = request.getHeader(HEADER);
                if (id == null) {
                    id = Baggage.current().getEntryValue(KEY);
                }
                if (id == null || !VALID.matcher(id).matches()) {
                    chain.doFilter(request, response);
                    return;
                }
                Span.current().setAttribute(KEY, id);
                MDC.put(KEY, id);
                try (Scope ignored = Baggage.current().toBuilder().put(KEY, id).build().makeCurrent()) {
                    chain.doFilter(request, response);
                } finally {
                    MDC.remove(KEY);
                }
            }
        };
    }

    @Bean
    RestClientCustomizer orderIdHeader() {
        return builder -> builder.requestInterceptor((request, body, execution) -> {
            String id = current();
            if (id != null) {
                request.getHeaders().set(HEADER, id);
            }
            return execution.execute(request, body);
        });
    }
}
