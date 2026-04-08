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
package org.polarsys.capella.test.framework.api;

import java.util.HashSet;
import java.util.Set;

import org.eclipse.core.commands.operations.IUndoContext;
import org.eclipse.emf.common.command.CommandStack;
import org.eclipse.emf.transaction.TransactionalEditingDomain;
import org.eclipse.sirius.business.api.session.Session;
import org.polarsys.capella.common.ef.internal.command.WorkspaceCommandStackImpl;
import org.polarsys.capella.test.framework.helpers.GuiActions;

/**
 * A test case that discard all changes to the test model at the end of test case.
 */
public abstract class NonDirtyTestCase extends BasicTestCase {

  private static final String RACE_TRACE_PROPERTY = "capella.test.framework.trace.sessionLifecycle";

  private Set<String> modelsWithModifiedUndoContexts = new HashSet<>();

  @Override
  protected Session getSession(String relativeModelPath) {
    Session session = super.getSession(relativeModelPath);
    if (session != null && !modelsWithModifiedUndoContexts.contains(relativeModelPath)) {
      setUndoContextLimit(session);
      modelsWithModifiedUndoContexts.add(relativeModelPath);
    }

    return session;
  }

  protected void setUndoContextLimit(Session session) {
    TransactionalEditingDomain transactionalEditingDomain = session.getTransactionalEditingDomain();
    if (transactionalEditingDomain != null) {
      WorkspaceCommandStackImpl commandStack = (WorkspaceCommandStackImpl) transactionalEditingDomain.getCommandStack();
      if (commandStack != null) {
        IUndoContext undoContext = commandStack.getDefaultUndoContext();
        commandStack.getOperationHistory().setLimit(undoContext, 10000);
      }
    }
  }

  @Override
  protected void tearDown() throws Exception {
    GuiActions.flushASyncGuiJobs();
    if (ModelProviderHelper.getInstance().getModelProvider().undoTestCaseChanges()) {
      undoAllChanges();
    }
    super.tearDown();
  }

  protected void undoAllChanges() {
    for (String testModel : getRequiredTestModels()) {
      Session session = AbstractProvider.getExistingSessionForTestModel(testModel, this);
      if (session == null) {
        traceSessionLifecycle("skip-undo-no-session", testModel, null);
        continue;
      }
      if (!session.isOpen()) {
        traceSessionLifecycle("skip-undo-closed-session", testModel, session);
        continue;
      }

      traceSessionLifecycle("undo-open-session", testModel, session);
      CommandStack commandStack = session.getTransactionalEditingDomain().getCommandStack();
      while (commandStack.canUndo()) {
        commandStack.undo();
      }
    }
  }

  private void traceSessionLifecycle(String event, String testModel, Session session) {
    if (!Boolean.getBoolean(RACE_TRACE_PROPERTY)) {
      return;
    }
    String state = session == null ? "null" : Boolean.toString(session.isOpen());
    System.out.println("[SESSION-RACE] event=" + event + " testModel=" + testModel + " sessionOpen=" + state);
  }
}
