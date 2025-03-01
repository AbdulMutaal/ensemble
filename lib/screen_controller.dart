import 'dart:async';
import 'dart:convert';
import 'dart:developer';

import 'package:ensemble/ensemble.dart';
import 'package:ensemble/framework/error_handling.dart';
import 'package:ensemble/framework/action.dart';
import 'package:ensemble/framework/data_context.dart';
import 'package:ensemble/framework/scope.dart';
import 'package:ensemble/framework/widget/toast.dart';
import 'package:ensemble/layout/ensemble_page_route.dart';
import 'package:ensemble/page_model.dart';
import 'package:ensemble/util/http_utils.dart';
import 'package:ensemble/framework/widget/view.dart';
import 'package:ensemble/util/utils.dart';
import 'package:ensemble/widget/unknown_builder.dart';
import 'package:ensemble/widget/widget_builder.dart' as ensemble;
import 'package:ensemble/widget/widget_registry.dart';
import 'package:ensemble/framework/widget/widget.dart';
import 'package:event_bus/event_bus.dart';
import 'package:flutter/material.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:http/http.dart' as http;
import 'package:ensemble_ts_interpreter/invokables/invokable.dart';
import 'package:yaml/yaml.dart';


/// Singleton that holds the page model definition
/// and operations for the current screen
class ScreenController {
  final WidgetRegistry registry = WidgetRegistry.instance;

  // Singleton
  static final ScreenController _instance = ScreenController._internal();
  ScreenController._internal();
  factory ScreenController() {
    return _instance;
  }

  // TODO: Back button will still use the curent page PageMode. Need to keep model state
  /// render the page from the definition and optional arguments (from previous pages)
  View renderPage(DataContext dataContext, YamlMap data, {bool? asModal}) {
    PageModel pageModel = PageModel(data);
    pageModel.pageType = asModal == true ? PageType.modal : PageType.regular;

    // add all the API names to our context as Invokable, even though their result
    // will be null. This is so we can always reference it API responses come back
    pageModel.apiMap?.forEach((key, value) {
      // have to be careful here. API response on page load may exists,
      // don't overwrite if that is the case
      if (!dataContext.hasContext(key)) {
        dataContext.addInvokableContext(key, APIResponse());
      }
    });

    /// Upon hot reload a new View is being created, but since the key
    /// is the same as the previously identify View, Flutter did not
    /// switch the View properly. Here we are just making sure every View
    /// will always be unique.
    /// TODO: a better way is to copy data to the new View so we don't waste time creating new one (Use pageName as key?)
    View initialView = View(
        // remove unique key as it causes multiple rendering of the Root.
        // Does it cause listeners to go hay-wired?
        //key: UniqueKey(),
        dataContext: dataContext,
        pageModel: pageModel);
    //log("View created ${initialView.hashCode}");
    return initialView;


  }


  /*
  pageModel.rootWidgetModel
        scopeManager.buildWidget(pageModel.rootWidgetModel),
        menu: pageModel.menu,
        footer: _buildFooter(scopeManager, pageModel)
   */

  @Deprecated('Use ScopeManager.buildWidget()')
  List<Widget> _buildChildren(DataContext eContext, List<WidgetModel> models) {
    List<Widget> children = [];
    for (WidgetModel model in models) {
      children.add(buildWidget(eContext, model));
    }
    return children;
  }

  /// build a widget from a given model
  @Deprecated('Use ScopeManager.buildWidget()')
  Widget buildWidget(DataContext eContext, WidgetModel model) {
    Function? widgetInstance = WidgetRegistry.widgetMap[model.type];
    if (widgetInstance != null) {
      Invokable widget = widgetInstance.call();

      // set props and styles on the widget. At this stage the widget
      // has not been attached, so no worries about ValueNotifier
      for (String key in model.props.keys) {
        if (widget.getSettableProperties().contains(key)) {
          widget.setProperty(key, model.props[key]);
        }
      }
      for (String key in model.styles.keys) {
        if (widget.getSettableProperties().contains(key)) {
          widget.setProperty(key, model.styles[key]);
        }
      }
      // save a mapping to the widget ID to our context
      if (model.props.containsKey('id')) {
        eContext.addInvokableContext(model.props['id'], widget);
      }

      // build children and pass itemTemplate for Containers
      if (widget is UpdatableContainer) {
        List<Widget>? layoutChildren;
        if (model.children != null) {
          layoutChildren = _buildChildren(eContext, model.children!);
        }
        (widget as UpdatableContainer).initChildren(children: layoutChildren, itemTemplate: model.itemTemplate);
      }

      return widget as HasController;
    } else {
      WidgetBuilderFunc builderFunc = WidgetRegistry.widgetBuilders[model.type]
          ?? UnknownBuilder.fromDynamic;
      ensemble.WidgetBuilder builder = builderFunc(
          model.props,
          model.styles,
          registry: registry);

      // first create the child widgets for layouts
      List<Widget>? layoutChildren;
      if (model.children != null) {
        layoutChildren = _buildChildren(eContext, model.children!);
      }

      // create the widget
      return builder.buildWidget(children: layoutChildren, itemTemplate: model.itemTemplate);
    }

  }

  /// handle Action e.g invokeAPI
  void executeAction(BuildContext context, EnsembleAction action) {
    // get the current scope of the widget that invoked this. It gives us
    // the data context to evaluate expression
    ScopeManager? scopeManager = DataScopeWidget.getScope(context);
    if (scopeManager != null) {
      executeActionWithScope(context, scopeManager, action);
    }
  }
  void executeActionWithScope(BuildContext context, ScopeManager scopeManager, EnsembleAction action) {
    _executeAction(context, scopeManager.dataContext, action, scopeManager.pageData.apiMap, scopeManager);
  }

  /// internally execute an Action
  void _executeAction(BuildContext context, DataContext providedDataContext, EnsembleAction action, Map<String, YamlMap>? apiMap, ScopeManager? scopeManager) {
    /// Actions are short-live so we don't need a childScope, simply create a localized context from the given context
    /// Note that scopeManager may starts out without Invokable IDs (as widgets may yet to render), but at the time
    /// of API returns, they will be populated. For this reason, always rebuild data context from scope manager.
    /// For now we are OK as we don't send off the API until the screen has rendered.
    DataContext dataContext = providedDataContext.clone(newBuildContext: context);
    /*DataContext dataContext;
    if (scopeManager != null) {
      // start with data context from scope manager but overwrite with provided data context
      dataContext = scopeManager.dataContext.clone(newBuildContext: context);
      dataContext.copy(providedDataContext, replaced: true);
    } else {
      dataContext = providedDataContext.clone(newBuildContext: context);
    }*/

    // scope the initiator to *this* variable
    if (action.initiator != null) {
      dataContext.addInvokableContext('this', action.initiator!);
    }

    if (action is InvokeAPIAction) {
      YamlMap? apiDefinition = apiMap?[action.apiName];
      if (apiDefinition != null) {
        // evaluate input arguments and add them to context
        if (apiDefinition['inputs'] is YamlList && action.inputs != null) {
          for (var input in apiDefinition['inputs']) {
            dynamic value = dataContext.eval(action.inputs![input]);
            if (value != null) {
              dataContext.addDataContextById(input, value);
            }
          }
        }

        HttpUtils.invokeApi(apiDefinition, dataContext)
            .then((response) => _onAPIComplete(context, dataContext, action, apiDefinition, Response(response), apiMap, scopeManager))
            .onError((error, stackTrace) => processAPIError(context, dataContext, apiDefinition, error, apiMap, scopeManager));
      }
    } else if (action is BaseNavigateScreenAction) {
      // process input parameters
      Map<String, dynamic>? nextArgs = {};
      action.inputs?.forEach((key, value) {
        nextArgs[key] = dataContext.eval(value);
      });

      PageRouteBuilder routeBuilder = Ensemble().navigateApp(
          providedDataContext.buildContext,
          screenName: dataContext.eval(action.screenName),
          asModal: action.asModal,
          pageArgs: nextArgs);

      // process onModalDismiss
      if (action is NavigateModalScreenAction &&
          action.onModalDismiss != null &&
          routeBuilder is EnsembleModalPageRouteBuilder &&
          scopeManager != null) {
        // callback on modal pop
        routeBuilder.popped.whenComplete(() {
          executeActionWithScope(context, scopeManager, action.onModalDismiss!);
        });
      }

    } else if (action is ShowDialogAction) {
      if (scopeManager != null) {
        Widget content = scopeManager.buildWidgetFromDefinition(action.content);

        // get styles. TODO: make bindable
        Map<String, dynamic> dialogStyles = {};
        action.options?.forEach((key, value) {
          dialogStyles[key] = dataContext.eval(value);
        });

        BuildContext? dialogContext;

        showGeneralDialog(
          context: context,
          barrierDismissible: true,
          barrierLabel: "Barrier",
          barrierColor: Colors.black54,

          pageBuilder: (context, animation, secondaryAnimation) {
            // save a reference to the builder's context so we can close it programmatically
            dialogContext = context;
            scopeManager.openedDialogs.add(dialogContext!);

            return Align(
              alignment: Alignment(
                Utils.getDouble(dialogStyles['horizontalOffset'], min: -1, max: 1, fallback: 0),
                Utils.getDouble(dialogStyles['verticalOffset'], min: -1, max: 1, fallback: 0)
              ),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minWidth: Utils.getDouble(dialogStyles['minWidth'], fallback: 0),
                    maxWidth: Utils.getDouble(dialogStyles['maxWidth'], fallback: double.infinity),
                    minHeight: Utils.getDouble(dialogStyles['minHeight'], fallback: 0),
                    maxHeight: Utils.getDouble(dialogStyles['maxHeight'], fallback: double.infinity)
                  ),
                  child: Container(
                      decoration: const BoxDecoration(
                        color: Colors.white,
                          borderRadius: BorderRadius.all(Radius.circular(5)),
                          boxShadow: <BoxShadow>[
                            BoxShadow(
                              color: Colors.white38,
                              blurRadius: 5,
                              offset: Offset(0, 0),
                            )
                          ]
                      ),
                    child: SingleChildScrollView (
                      child: content,
                    )
                  )
                )
              )

            );
          }
        ).then((value) {
          // remove the dialog context since we are closing them
          scopeManager.openedDialogs.remove(dialogContext);
          
          // callback when dialog is dismissed
          if (action.onDialogDismiss != null) {
            executeActionWithScope(context, scopeManager, action.onDialogDismiss!);
          }
        });
      }
    } else if (action is CloseAllDialogsAction) {
      if (scopeManager != null) {
        for (var dialogContext in scopeManager.openedDialogs) {
          Navigator.pop(dialogContext);
        }
        scopeManager.openedDialogs.clear();
      }

    } else if (action is StartTimerAction) {

      // what happened if ScopeManager is null?
      if (scopeManager != null) {

        int delay = action.payload?.startAfter ??
          (action.payload?.repeat == true ? action.payload?.repeatInterval ?? 0 : 0);

        // we always execute at least once, delayed by startAfter and fallback to repeatInterval (or immediate if startAfter is 0)
        Timer(
          Duration(seconds: delay),
          () {
            // execute the action
            executeActionWithScope(context, scopeManager, action.onTimer);

            // if no repeat, execute onTimerComplete
            if (action.payload?.repeat != true) {
              if (action.onTimerComplete != null) {
                executeActionWithScope(context, scopeManager, action.onTimerComplete!);
              }
            }
            // else repeating timer
            else if (action.payload?.repeatInterval != null) {
              /// repeatCount value of null means forever by default
              int? repeatCount;
              if (action.payload?.maxTimes != null) {
                repeatCount = action.payload!.maxTimes! - 1;
              }
              if (repeatCount != 0) {
                int counter = 0;
                final timer = Timer.periodic(
                  Duration(seconds: action.payload!.repeatInterval!),
                  (timer) {
                    // execute the action
                    executeActionWithScope(context, scopeManager, action.onTimer);

                    // automatically cancel timer when repeatCount is reached
                    if (repeatCount != null && ++counter == repeatCount) {
                      timer.cancel();

                      // timer terminates, call onTimerComplete
                      if (action.onTimerComplete != null) {
                        executeActionWithScope(context, scopeManager, action.onTimerComplete!);
                      }
                    }
                  }
                );

                // save our timer to our PageData since user may want to cancel at anytime
                // and also when we navigate away from the page
                if (action.initiator != null) {
                  saveTimerReference(scopeManager, action.initiator!, timer);
                }

              }
            }

          }
        );
      }


    } else if (action is ExecuteCodeAction) {
      dataContext.evalCode(action.codeBlock);

      if (action.onComplete != null && scopeManager != null) {
        executeActionWithScope(context, scopeManager, action.onComplete!);
      }
    } else if (action is ShowToastAction) {
      Widget? customToastBody;
      if (scopeManager != null && action.type == ToastType.custom && action.body != null) {
        customToastBody = scopeManager.buildWidgetFromDefinition(action.body);
      }
      ToastController().showToast(context, action, customToastBody);

      
    }
  }

  /// executing a code block
  /// also scope the Initiator to *this* variable
  /*void executeCodeBlock(DataContext dataContext, Invokable initiator, String codeBlock) {
    // scope the initiator to *this* variable
    DataContext localizedContext = dataContext.clone();
    localizedContext.addInvokableContext('this', initiator);
    localizedContext.evalCode(codeBlock);
  }*/

  /// e.g upon return of API result
  void _onAPIComplete(BuildContext context, DataContext dataContext, InvokeAPIAction action, YamlMap apiDefinition, Response response, Map<String, YamlMap>? apiMap, ScopeManager? scopeManager) {
    // first execute API's onResponse code block
    EnsembleAction? onResponse = Utils.getAction(apiDefinition['onResponse'], initiator: action.initiator);
    if (onResponse != null) {
      processAPIResponse(context, dataContext, onResponse, response, apiMap, scopeManager, apiChangeHandler: dispatchAPIChanges, action: action, modifiableAPIResponse: true);
    }
    // dispatch changes even if we don't have onResponse
    else {
      dispatchAPIChanges(scopeManager, action, APIResponse(response: response));
    }

    // if our Action has onResponse, invoke that next
    if (action.onResponse != null) {
      processAPIResponse(context, dataContext, action.onResponse!, response, apiMap, scopeManager);
    }



  }

  void dispatchAPIChanges(ScopeManager? scopeManager, InvokeAPIAction action, APIResponse apiResponse) {
    // update the API response in our DataContext and fire changes to all listeners.
    // Make sure we don't override the key here, as all the scopes referenced the same API
    if (scopeManager != null) {
      dynamic api = scopeManager.dataContext.getContextById(action.apiName);
      if (api == null || api is! Invokable) {
        throw RuntimeException(
            "Unable to update API Binding as it doesn't exists");
      }
      Response? _response = apiResponse.getAPIResponse();
      if (_response != null) {
        // update the API response so all references get it
        (api as APIResponse).setAPIResponse(_response);

        // dispatch changes
        scopeManager.dispatch(ModelChangeEvent(action.apiName, api));
      }
    }
  }

  /// Executing the onResponse action. Note that this can be
  /// the API's onResponse or a caller's onResponse (e.g. onPageLoad's onResponse)
  void processAPIResponse(BuildContext context, DataContext dataContext, EnsembleAction onResponseAction, Response response, Map<String, YamlMap>? apiMap, ScopeManager? scopeManager, {Function? apiChangeHandler, InvokeAPIAction? action, bool? modifiableAPIResponse}) {
    // execute the onResponse on the API definition
    APIResponse apiResponse = modifiableAPIResponse == true ?
      ModifiableAPIResponse(response: response) :
      APIResponse(response: response);

    DataContext localizedContext = dataContext.clone();
    localizedContext.addInvokableContext('response', apiResponse);
    _executeAction(context, localizedContext, onResponseAction, apiMap, scopeManager);

    if (modifiableAPIResponse == true) {
      // should be on Action's callback instead
      apiChangeHandler?.call(scopeManager, action, apiResponse);
    }
  }

  /// executing the onError action
  void processAPIError(BuildContext context, DataContext dataContext, YamlMap apiDefinition, Object? error, Map<String, YamlMap>? apiMap, ScopeManager? scopeManager) {
    log("Error: $error");

    EnsembleAction? onErrorAction = Utils.getAction(apiDefinition['onError']);
    if (onErrorAction != null) {
      // probably want to include the error?
      _executeAction(context, dataContext, onErrorAction, apiMap, scopeManager);
    }

    // silently fail if error handle is not defined? or should we alert user?
  }

  void processCodeBlock(DataContext eContext, String codeBlock) {
    try {
      eContext.evalCode(codeBlock);
    } catch (e) {
      print ("Code block exception: " + e.toString());
    }
  }

  void saveTimerReference(ScopeManager scopeManager, Invokable initiator, Timer timer) {
    Map<Invokable, Timer> timerMap = scopeManager.timerMap;

    // clean up existing duplicates first
    timerMap[initiator]?.cancel();

    timerMap[initiator] = timer;
  }






}
