package org.lgtm.demo;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

import io.opentelemetry.instrumentation.annotations.SpanAttribute;
import io.opentelemetry.instrumentation.annotations.WithSpan;
import org.springframework.stereotype.Component;

/** Deliberately burns CPU so the span shows up in the linked CPU profile (span profiles). */
@Component
class PriceCalculator {

    @WithSpan("calculate-price")
    long calculate(@SpanAttribute("shop.item") String item) {
        int rounds = item.equals("anvil") ? 200_000 : 20_000;
        byte[] hash = item.getBytes(StandardCharsets.UTF_8);
        try {
            MessageDigest sha = MessageDigest.getInstance("SHA-256");
            for (int i = 0; i < rounds; i++) {
                hash = sha.digest(hash);
            }
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
        return 100 + Math.floorMod(hash[0], 900);
    }
}
