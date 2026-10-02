package com.example.vaultaot.timing;

import java.lang.management.ManagementFactory;
import java.time.Duration;

import org.apache.commons.logging.Log;
import org.apache.commons.logging.LogFactory;

import org.springframework.aot.AotDetector;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.SpringApplicationRunListener;
import org.springframework.boot.bootstrap.ConfigurableBootstrapContext;
import org.springframework.context.ConfigurableApplicationContext;
import org.springframework.core.Ordered;
import org.springframework.core.env.ConfigurableEnvironment;
import org.springframework.core.metrics.ApplicationStartup;

import static com.example.vaultaot.timing.StepTimingApplicationStartup.BEAN_DEFINITIONS;
import static com.example.vaultaot.timing.StepTimingApplicationStartup.CONFIG_ENHANCE;
import static com.example.vaultaot.timing.StepTimingApplicationStartup.CONFIG_PARSE;
import static com.example.vaultaot.timing.StepTimingApplicationStartup.REFRESH;
import static com.example.vaultaot.timing.StepTimingApplicationStartup.WEB_SERVER;

/**
 * Logs two lines per application start:
 * <ul>
 * <li>{@code STARTUP_TIMING}: JVM init, config loading, the part of it spent on Vault ({@code vault}, see
 * {@link VaultImportTiming}), Spring initialization, runners.
 * <li>{@code SPRING_INIT}: Spring initialization broken down - the part Spring AOT changes.
 * </ul>
 * Runs after Boot's own run listener, so the {@code environmentPrepared} timestamp is taken
 * after config-data loading - including the whole {@code vault://} fetch, if there is one.
 * Logging is muted while config data loads, so everything is reported once, at ready.
 * <p>
 * Set {@code startup-timing.exit-after-ready=true} to exit right after reporting (benchmark loops).
 */
public class StartupTimingRunListener implements SpringApplicationRunListener, Ordered {

    private static final Log logger = LogFactory.getLog(StartupTimingRunListener.class);

    private final StepTimingApplicationStartup steps = new StepTimingApplicationStartup();
    private final boolean stepsInstalled;

    private long starting;
    private long envPrepared;
    private long contextLoaded;
    private long started;

    public StartupTimingRunListener(SpringApplication application, String[] args) {
        // Boot creates run listeners before it hands the ApplicationStartup to the context,
        // so installing it here needs no code in the app. Leave an app's own choice alone.
        stepsInstalled = application.getApplicationStartup() == ApplicationStartup.DEFAULT;
        if (stepsInstalled) {
            application.setApplicationStartup(steps);
        }
    }

    @Override
    public int getOrder() {
        return Ordered.LOWEST_PRECEDENCE;
    }

    @Override
    public void starting(ConfigurableBootstrapContext bootstrapContext) {
        starting = System.nanoTime();
    }

    @Override
    public void environmentPrepared(ConfigurableBootstrapContext bootstrapContext, ConfigurableEnvironment environment) {
        envPrepared = System.nanoTime();
    }

    @Override
    public void contextLoaded(ConfigurableApplicationContext context) {
        contextLoaded = System.nanoTime();
    }

    @Override
    public void started(ConfigurableApplicationContext context, Duration timeTaken) {
        started = System.nanoTime();
    }

    @Override
    public void ready(ConfigurableApplicationContext context, Duration timeTaken) {
        long ready = System.nanoTime();
        // JVM start is only known in wall-clock time; anchor it to the nanoTime timeline at 'ready'.
        long totalMs = System.currentTimeMillis() - ManagementFactory.getRuntimeMXBean().getStartTime();
        long jvmInitMs = totalMs - ms(starting, ready);
        String app = context.getEnvironment().getProperty("spring.application.name", "application");
        boolean aot = AotDetector.useGeneratedArtifacts();
        long springInit = ms(envPrepared, started);

        logger.info(String.format(
                "STARTUP_TIMING app=%s aot=%s jvm_init=%dms env_prepare=%dms vault=%dms spring_init=%dms runners=%dms total=%dms",
                app, aot, jvmInitMs, ms(starting, envPrepared), VaultImportTiming.millis(), springInit, ms(started, ready),
                totalMs));
        if (stepsInstalled) {
            long refresh = steps.millis(REFRESH);
            long beanDefinitions = steps.millis(BEAN_DEFINITIONS);
            long webServer = steps.millis(WEB_SERVER);
            logger.info(String.format(
                    "SPRING_INIT app=%s aot=%s spring_init=%dms context_prepare=%dms refresh=%dms bean_definitions=%dms "
                            + "config_classes=%dms web_server=%dms bean_creation=%dms",
                    app, aot, springInit, ms(envPrepared, contextLoaded), refresh, beanDefinitions,
                    steps.millis(CONFIG_PARSE) + steps.millis(CONFIG_ENHANCE), webServer,
                    Math.max(0, refresh - beanDefinitions - webServer)));
        }

        if (context.getEnvironment().getProperty("startup-timing.exit-after-ready", Boolean.class, false)) {
            System.exit(SpringApplication.exit(context));
        }
    }

    private static long ms(long fromNanos, long toNanos) {
        return (toNanos - fromNanos) / 1_000_000;
    }
}
