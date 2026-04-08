/*******************************************************************************
 * Copyright (c) 2017, 2020 THALES GLOBAL SERVICES.
 * 
 * This program and the accompanying materials are made available under the
 * terms of the Eclipse Public License 2.0 which is available at
 * http://www.eclipse.org/legal/epl-2.0
 * 
 * SPDX-License-Identifier: EPL-2.0
 * 
 * Contributors:
 *    Thales - initial API and implementation
 *******************************************************************************/
package org.polarsys.capella.test.migration.ju.helpers;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import org.eclipse.core.resources.IProject;
import org.eclipse.core.runtime.jobs.Job;
import org.eclipse.ui.progress.UIJob;
import org.eclipse.ui.PlatformUI;
import org.osgi.framework.FrameworkUtil;
import org.polarsys.capella.core.data.migration.MigrationConstants;
import org.polarsys.capella.core.data.migration.MigrationHelpers;
import org.polarsys.capella.test.framework.helpers.GuiActions;

public class MigrationHelper {

  public static final String DEBUG_REVISION = "relation-debug-2026-04-08T16:55Z-r1";
  private static final String TRACE_PROPERTY = "capella.test.migration.relation.trace";
  private static final String PERTURBATION_PROPERTY = "capella.test.migration.relation.perturbation";
  private static final int MAX_STABILIZATION_ROUNDS = 200;
  private static final int REQUIRED_IDLE_ROUNDS = 5;
  private static final long STABILIZATION_DELAY_MS = 50L;
  private static final String[] RELEVANT_BUNDLE_PREFIXES = { "org.polarsys", "org.eclipse.sirius", "org.eclipse.gmf",
      "org.eclipse.emf", "org.eclipse.ui", "org.eclipse.core.resources" };
  
  public static void migrateProject(IProject project) {
    boolean traceEnabled = isTraceEnabled();
    if (traceEnabled) {
      trace("migration-start revision=" + DEBUG_REVISION + " project=" + project.getName());
    }

    // Tests must wait for migration completion before reopening or asserting on the model.
    MigrationHelpers.getInstance().trigger(project, PlatformUI.getWorkbench().getActiveWorkbenchWindow().getShell(), false, true,
        false, MigrationConstants.DEFAULT_KIND_ORDER);

    // Migration can enqueue follow-up UI/polarsys jobs after trigger() returns.
    // Wait for a short "quiet window" before giving control back to tests.
    int idleRounds = 0;
    for (int i = 0; i < MAX_STABILIZATION_ROUNDS && idleRounds < REQUIRED_IDLE_ROUNDS; i++) {
      GuiActions.flushASyncGuiJobs();
      List<String> relevantJobs = describeRelevantAsyncJobs();
      if (traceEnabled && !relevantJobs.isEmpty()) {
        trace("migration-stabilization revision=" + DEBUG_REVISION + " round=" + i + " idleRounds=" + idleRounds
            + " jobs=" + relevantJobs);
      }
      idleRounds = relevantJobs.isEmpty() ? idleRounds + 1 : 0;
      try {
        Thread.sleep(STABILIZATION_DELAY_MS);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        break;
      }
    }

    if (traceEnabled) {
      trace("migration-end revision=" + DEBUG_REVISION + " project=" + project.getName() + " remainingJobs="
          + describeRelevantAsyncJobs());
    }
  }

  public static List<String> describeRelevantAsyncJobs() {
    List<String> relevantJobs = new ArrayList<>();
    for (Job job : Job.getJobManager().find(null)) {
      if (!isRelevant(job)) {
        continue;
      }
      relevantJobs.add(describeJob(job));
    }
    return relevantJobs;
  }

  public static boolean hasRelevantAsyncJobs() {
    return !describeRelevantAsyncJobs().isEmpty();
  }

  public static boolean isTraceEnabled() {
    if (Boolean.getBoolean(TRACE_PROPERTY)) {
      return true;
    }
    return !"none".equalsIgnoreCase(System.getProperty(PERTURBATION_PROPERTY, "none"));
  }

  private static boolean isRelevant(Job job) {
    if (job == null || job.getState() == Job.NONE) {
      return false;
    }
    if (job instanceof UIJob) {
      return true;
    }

    String className = job.getClass().getName().toLowerCase(Locale.ROOT);
    if (className.contains("sirius") || className.contains("gmf") || className.contains("diagram")
        || className.contains("layout") || className.contains("refresh")) {
      return true;
    }

    String symbolicName = getSymbolicName(job);
    if (symbolicName != null) {
      for (String prefix : RELEVANT_BUNDLE_PREFIXES) {
        if (symbolicName.startsWith(prefix)) {
          return true;
        }
      }
    }
    return false;
  }

  private static String describeJob(Job job) {
    String bundle = getSymbolicName(job);
    return job.getName() + "|class=" + job.getClass().getName() + "|state=" + stateToString(job.getState()) + "|uiJob="
        + (job instanceof UIJob) + "|bundle=" + (bundle == null ? "MISSING" : bundle);
  }

  private static String getSymbolicName(Job job) {
    try {
      if (FrameworkUtil.getBundle(job.getClass()) == null) {
        return null;
      }
      return FrameworkUtil.getBundle(job.getClass()).getSymbolicName();
    } catch (Exception e) {
      return null;
    }
  }

  private static String stateToString(int state) {
    switch (state) {
    case Job.NONE:
      return "NONE";
    case Job.SLEEPING:
      return "SLEEPING";
    case Job.WAITING:
      return "WAITING";
    case Job.RUNNING:
      return "RUNNING";
    default:
      return Integer.toString(state);
    }
  }

  private static void trace(String message) {
    System.out.println("[RELDBG] " + message);
    System.out.flush();
  }

  private MigrationHelper() {
    // helpers only
  }

}
