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

  private static final int MAX_STABILIZATION_ROUNDS = 200;
  private static final int REQUIRED_IDLE_ROUNDS = 5;
  private static final long STABILIZATION_DELAY_MS = 50L;
  private static final String[] RELEVANT_BUNDLE_PREFIXES = { "org.polarsys", "org.eclipse.sirius", "org.eclipse.gmf",
      "org.eclipse.emf", "org.eclipse.ui", "org.eclipse.core.resources" };
  
  public static void migrateProject(IProject project) {
    // Migration can return before Sirius and GMF have finished their follow-up work.
    // Keep tests blocked until the UI and related jobs stay idle for a short quiet
    // window, otherwise reopening the migrated model races with that background work.
    MigrationHelpers.getInstance().trigger(project, PlatformUI.getWorkbench().getActiveWorkbenchWindow().getShell(),
        false, true, false, MigrationConstants.DEFAULT_KIND_ORDER);

    int idleRounds = 0;
    for (int i = 0; i < MAX_STABILIZATION_ROUNDS && idleRounds < REQUIRED_IDLE_ROUNDS; i++) {
      GuiActions.flushASyncGuiJobs();
      idleRounds = hasRelevantAsyncJobs() ? 0 : idleRounds + 1;
      try {
        Thread.sleep(STABILIZATION_DELAY_MS);
      } catch (InterruptedException e) {
        Thread.currentThread().interrupt();
        break;
      }
    }
  }

  private static boolean hasRelevantAsyncJobs() {
    for (Job job : Job.getJobManager().find(null)) {
      if (isRelevant(job)) {
        return true;
      }
    }
    return false;
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

  private MigrationHelper() {
    // helpers only
  }

}
