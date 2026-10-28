package com.maxduke.guoguo_core;

import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.FutureTask;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.LongSupplier;

/** Keeps cancellation independent of provider IO and includes dispatch wait in its budget. */
final class ProviderCallDispatcher implements AutoCloseable {
    interface Work { Object run(int remainingMillis) throws Exception; }
    interface Result {
        void success(Object value);
        void failure(Exception error);
    }

    private final ThreadPoolExecutor providers = pool(3);
    private final ThreadPoolExecutor controls = pool(1);
    private final ScheduledThreadPoolExecutor deadlines = new ScheduledThreadPoolExecutor(1);
    private final LongSupplier now;

    ProviderCallDispatcher() { this(System::nanoTime); }

    ProviderCallDispatcher(LongSupplier now) {
        this.now = now;
        deadlines.setRemoveOnCancelPolicy(true);
        deadlines.setExecuteExistingDelayedTasksAfterShutdownPolicy(false);
    }

    private static ThreadPoolExecutor pool(int threads) {
        return new ThreadPoolExecutor(threads, threads, 0L, TimeUnit.MILLISECONDS,
                new ArrayBlockingQueue<>(32));
    }

    void execute(boolean control, int budgetMillis, Work work, Result result) {
        final ThreadPoolExecutor executor = control ? controls : providers;
        final long due = now.getAsLong() + TimeUnit.MILLISECONDS.toNanos(budgetMillis);
        // A deadline may finish queued work, but never discard a published core
        // result. Once running, the core owns the remaining context deadline.
        final AtomicInteger phase = new AtomicInteger(0); // queued, running, done
        final AtomicReference<ScheduledFuture<?>> alarm = new AtomicReference<>();
        final FutureTask<Void> task = new FutureTask<>(() -> {
            if (!phase.compareAndSet(0, 1)) return null;
            final ScheduledFuture<?> timer = alarm.get();
            if (timer != null) timer.cancel(false);
            try {
                final long nanos = due - now.getAsLong();
                final long remaining = nanos <= 0 ? 0 : (nanos + 999999) / 1000000;
                if (remaining < 100) throw new TimeoutException("站源请求排队超时，请重试");
                result.success(work.run((int) Math.min(75000, remaining)));
            } catch (Exception error) {
                result.failure(error);
            } finally {
                phase.set(2);
            }
            return null;
        });
        try {
            alarm.set(deadlines.schedule(() -> {
                if (phase.compareAndSet(0, 2)) {
                    executor.remove(task);
                    task.cancel(false);
                    result.failure(new TimeoutException("站源请求排队超时，请重试"));
                }
            }, budgetMillis, TimeUnit.MILLISECONDS));
            executor.execute(task);
            if (task.isCancelled()) executor.remove(task);
        } catch (RejectedExecutionException error) {
            final ScheduledFuture<?> timer = alarm.get();
            if (timer != null) timer.cancel(false);
            if (phase.compareAndSet(0, 2)) {
                result.failure(new RejectedExecutionException("站源请求繁忙，请稍后重试"));
            }
        }
    }

    @Override public void close() {
        providers.shutdownNow();
        controls.shutdownNow();
        deadlines.shutdownNow();
    }
}
