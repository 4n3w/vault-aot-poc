package com.example.vaultaot.timing;

import java.util.Collections;
import java.util.Iterator;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.function.Supplier;

import org.springframework.core.metrics.ApplicationStartup;
import org.springframework.core.metrics.StartupStep;

/**
 * Times the few startup steps Spring Framework and Boot record during context refresh. Every
 * other step goes to {@link ApplicationStartup#DEFAULT} (no-op), so this adds next to no overhead.
 */
class StepTimingApplicationStartup implements ApplicationStartup {

    /** The whole {@code AbstractApplicationContext.refresh()}. */
    static final String REFRESH = "spring.context.refresh";

    /** BeanFactoryPostProcessors (config parsing, component scan, conditions) + BeanPostProcessor registration. */
    static final String BEAN_DEFINITIONS = "spring.context.beans.post-process";

    /** {@code @Configuration} parsing - the part AOT replaces with generated code. */
    static final String CONFIG_PARSE = "spring.context.config-classes.parse";

    /** CGLIB enhancement of {@code @Configuration} classes - also done at build time with AOT. */
    static final String CONFIG_ENHANCE = "spring.context.config-classes.enhance";

    /** Creating the embedded web server (Tomcat + servlet context initialization). */
    static final String WEB_SERVER = "spring.boot.webserver.create";

    private static final Set<String> TRACKED = Set.of(REFRESH, BEAN_DEFINITIONS, CONFIG_PARSE, CONFIG_ENHANCE, WEB_SERVER);

    private final Map<String, Long> nanos = new ConcurrentHashMap<>();

    @Override
    public StartupStep start(String name) {
        return TRACKED.contains(name) ? new TimedStep(name) : ApplicationStartup.DEFAULT.start(name);
    }

    long millis(String name) {
        return nanos.getOrDefault(name, 0L) / 1_000_000;
    }

    private final class TimedStep implements StartupStep {

        private static final Tags NO_TAGS = new Tags() {
            @Override
            public Iterator<Tag> iterator() {
                return Collections.emptyIterator();
            }
        };

        private final String name;
        private final long start = System.nanoTime();

        TimedStep(String name) {
            this.name = name;
        }

        @Override
        public String getName() {
            return name;
        }

        @Override
        public long getId() {
            return 0;
        }

        @Override
        public Long getParentId() {
            return null;
        }

        @Override
        public StartupStep tag(String key, String value) {
            return this;
        }

        @Override
        public StartupStep tag(String key, Supplier<String> value) {
            return this;
        }

        @Override
        public Tags getTags() {
            return NO_TAGS;
        }

        @Override
        public void end() {
            nanos.merge(name, System.nanoTime() - start, Long::sum);
        }
    }
}
