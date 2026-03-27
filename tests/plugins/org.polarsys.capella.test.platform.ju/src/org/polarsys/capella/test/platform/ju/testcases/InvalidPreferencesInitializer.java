/*******************************************************************************
 * Copyright (c) 2019, 2020 THALES GLOBAL SERVICES.
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
package org.polarsys.capella.test.platform.ju.testcases;

import java.util.ArrayList;
import java.util.Collection;
import java.util.Set;
import java.util.TreeSet;
import java.util.stream.Collectors;

import org.eclipse.core.runtime.IConfigurationElement;
import org.eclipse.core.runtime.Platform;
import org.eclipse.core.runtime.preferences.AbstractPreferenceInitializer;
import org.eclipse.osgi.util.NLS;
import org.eclipse.ui.PlatformUI;
import org.eclipse.ui.activities.IActivityManager;
import org.polarsys.capella.test.framework.api.BasicTestCase;

/**
 * This test ensures that defined PreferenceInitializer are valid
 */
public class InvalidPreferencesInitializer extends BasicTestCase {

  @Override
  public void test() throws Exception {
    Collection<String> errors = new ArrayList<>();
    Set<String> skippedContributors = new TreeSet<>();
    IActivityManager activityManager = getActivityManager();
    IConfigurationElement[] configurationElements = Platform.getExtensionRegistry()
        .getConfigurationElementsFor("org.eclipse.core.runtime.preferences");
    
    for (IConfigurationElement element : configurationElements) {
      if ("initializer".equals(element.getName())) {
        String pluginId = element.getContributor().getName();
        if (activityManager != null && !isContributorEnabled(activityManager, pluginId)) {
          skippedContributors.add(pluginId);
          continue;
        }
        try {
          Object object = element.createExecutableExtension("class");
          if (!AbstractPreferenceInitializer.class.isInstance(object)) {
            errors.add(NLS.bind("{0} is not a valid initializer (plugin:{1})", element.getAttribute("class"), pluginId));
          }
        } catch (Exception e) {
          errors.add(NLS.bind("{0} (plugin:{1})", e.getMessage(), pluginId));
        }
      }
    }
    String failureMessage = errors.stream().collect(Collectors.joining("\n"));
    if (!skippedContributors.isEmpty()) {
      String skipped = skippedContributors.stream().collect(Collectors.joining(", "));
      failureMessage = failureMessage + NLS.bind("\nSkipped activity-disabled contributors: {0}", skipped);
    }
    assertTrue(failureMessage, errors.isEmpty());
  }

  private IActivityManager getActivityManager() {
    if (!PlatformUI.isWorkbenchRunning()) {
      return null;
    }
    return PlatformUI.getWorkbench().getActivitySupport().getActivityManager();
  }

  private boolean isContributorEnabled(IActivityManager activityManager, String pluginId) {
    String probeId = pluginId + "/__capella_pref_initializer_probe__";
    return activityManager.getIdentifier(probeId).isEnabled();
  }

}
