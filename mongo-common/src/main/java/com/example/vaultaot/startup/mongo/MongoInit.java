package com.example.vaultaot.startup.mongo;

import java.util.Locale;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

/**
 * How the app initializes Mongo, read from mongo.init (MONGO_INIT) at runtime. It is deliberately not a
 * {@code @Conditional}/{@code @Profile}: AOT would freeze that choice at build time (see 01-aot-breakage), while
 * a runtime value lets one image serve every mode, with AOT on or off.
 */
public final class MongoInit {

    private static final Log logger = LogFactory.getLog(MongoInit.class);

    public enum Mode {
        /** Indexes and the cache are loaded while the context starts; readiness includes Mongo. */
        BLOCKING,
        /** Same work on a virtual thread after the app is ready; readiness doesn't wait for Mongo. */
        DEFERRED,
        /** Same work as a reactive pipeline subscribed after the app is ready. */
        REACTIVE
    }

    private final Mode mode;

    private final String creds;

    public MongoInit(String mode, String creds) {
        this.mode = Mode.valueOf(mode.trim().toUpperCase(Locale.ROOT));
        this.creds = creds;
    }

    public Mode mode() {
        return mode;
    }

    /** One line per start, parsed by k3d.sh: blocking = on the startup path, background = after ready. */
    public void report(long blockingMs, long backgroundMs, int items) {
        logger.info(String.format("MONGO_INIT mode=%s creds=%s items=%d blocking=%dms background=%dms",
                mode.name().toLowerCase(Locale.ROOT), creds, items, blockingMs, backgroundMs));
    }
}
