package com.example.vaultaot.timing;

import java.io.IOException;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Function;

import org.springframework.beans.BeanUtils;
import org.springframework.boot.context.config.ConfigData;
import org.springframework.boot.context.config.ConfigDataLoader;
import org.springframework.boot.context.config.ConfigDataLoaderContext;
import org.springframework.boot.context.config.ConfigDataLocation;
import org.springframework.boot.context.config.ConfigDataLocationResolver;
import org.springframework.boot.context.config.ConfigDataLocationResolverContext;
import org.springframework.boot.context.config.ConfigDataResource;
import org.springframework.boot.context.config.Profiles;
import org.springframework.boot.logging.DeferredLogFactory;
import org.springframework.core.Ordered;
import org.springframework.util.ClassUtils;
import org.springframework.util.ReflectionUtils;

/**
 * Times Spring Cloud Vault's config import ({@code vault://}): resolving it, creating the Vault
 * client, logging in and reading the secrets. Logging is muted while config data loads, so
 * {@link StartupTimingRunListener} reports the total later as {@code vault=...ms}.
 * <p>
 * A resolver that runs before Vault's own one delegates to it and wraps each resolved resource, so
 * the wrapped resources come to this loader, which delegates to Vault's loader. Vault's classes are
 * created reflectively: in an app without Spring Cloud Vault this resolver never matches.
 */
final class VaultImportTiming {

    private static final String VAULT_RESOLVER = "org.springframework.cloud.vault.config.VaultConfigDataLocationResolver";
    private static final String VAULT_LOADER = "org.springframework.cloud.vault.config.VaultConfigDataLoader";

    private static final AtomicLong nanos = new AtomicLong();

    private VaultImportTiming() {
    }

    static long millis() {
        return nanos.get() / 1_000_000;
    }

    private static <T> T timed(ThrowingSupplier<T> work) throws Exception {
        long start = System.nanoTime();
        try {
            return work.get();
        }
        finally {
            nanos.addAndGet(System.nanoTime() - start);
        }
    }

    @SuppressWarnings("unchecked")
    private static <T> T instantiate(String className, Function<Class<?>, T> creator) {
        ClassLoader classLoader = VaultImportTiming.class.getClassLoader();
        if (!ClassUtils.isPresent(className, classLoader)) {
            return null;
        }
        return creator.apply(ClassUtils.resolveClassName(className, classLoader));
    }

    @FunctionalInterface
    private interface ThrowingSupplier<T> {
        T get() throws Exception;
    }

    /** A Vault resource, wrapped so that {@link Loader} (not Vault's loader) picks it up. */
    public static final class Resource extends ConfigDataResource {

        private final ConfigDataResource delegate;

        Resource(ConfigDataResource delegate) {
            super(isOptional(delegate));
            this.delegate = delegate;
        }

        // ConfigDataResource.isOptional() is package-private; Vault's resource makes it public.
        private static boolean isOptional(ConfigDataResource resource) {
            Method method = ReflectionUtils.findMethod(resource.getClass(), "isOptional");
            return method != null && Modifier.isPublic(method.getModifiers())
                    && Boolean.TRUE.equals(ReflectionUtils.invokeMethod(method, resource));
        }

        @Override
        public boolean equals(Object other) {
            return other instanceof Resource resource && delegate.equals(resource.delegate);
        }

        @Override
        public int hashCode() {
            return delegate.hashCode();
        }

        @Override
        public String toString() {
            return delegate.toString();
        }
    }

    /** Registered in spring.factories; ordered before Vault's resolver. */
    @SuppressWarnings({ "rawtypes", "unchecked" })
    public static final class Resolver implements ConfigDataLocationResolver<Resource>, Ordered {

        private final ConfigDataLocationResolver delegate =
                instantiate(VAULT_RESOLVER, type -> (ConfigDataLocationResolver) BeanUtils.instantiateClass(type));

        @Override
        public int getOrder() {
            return Ordered.HIGHEST_PRECEDENCE;
        }

        @Override
        public boolean isResolvable(ConfigDataLocationResolverContext context, ConfigDataLocation location) {
            return delegate != null && delegate.isResolvable(context, location);
        }

        @Override
        public List<Resource> resolve(ConfigDataLocationResolverContext context, ConfigDataLocation location) {
            return wrap(() -> delegate.resolve(context, location));
        }

        @Override
        public List<Resource> resolveProfileSpecific(ConfigDataLocationResolverContext context,
                ConfigDataLocation location, Profiles profiles) {
            return wrap(() -> delegate.resolveProfileSpecific(context, location, profiles));
        }

        private List<Resource> wrap(ThrowingSupplier<List<ConfigDataResource>> resolve) {
            try {
                return timed(resolve).stream().map(Resource::new).toList();
            }
            catch (RuntimeException ex) {
                throw ex;
            }
            catch (Exception ex) {
                throw new IllegalStateException(ex);
            }
        }
    }

    /** Registered in spring.factories; handles only {@link Resource}, so it never competes with Vault's loader. */
    @SuppressWarnings({ "rawtypes", "unchecked" })
    public static final class Loader implements ConfigDataLoader<Resource> {

        private final ConfigDataLoader delegate;

        public Loader(DeferredLogFactory logFactory) {
            this.delegate = instantiate(VAULT_LOADER,
                    type -> (ConfigDataLoader) BeanUtils.instantiateClass(
                            ClassUtils.getConstructorIfAvailable(type, DeferredLogFactory.class), logFactory));
        }

        @Override
        public boolean isLoadable(ConfigDataLoaderContext context, Resource resource) {
            return delegate != null && delegate.isLoadable(context, resource.delegate);
        }

        @Override
        public ConfigData load(ConfigDataLoaderContext context, Resource resource) throws IOException {
            try {
                return timed(() -> delegate.load(context, resource.delegate));
            }
            catch (IOException | RuntimeException ex) {
                throw ex;
            }
            catch (Exception ex) {
                throw new IllegalStateException(ex);
            }
        }
    }
}
